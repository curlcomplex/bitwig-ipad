// StikJIT script for this Java 25 runtime's legacy BRK 0x69 allocator.
// Unlike the universal script's sentinel handshake, x0 here is the allocation
// size and must be replaced with the prepared executable mapping address.
function fromLE(hex) {
    let n=0n;for(let i=hex.length-2;i>=0;i-=2)n=(n<<8n)|BigInt('0x'+hex.slice(i,i+2));return n;
}
function toLE(n) {
    let out='';for(let i=0;i<8;i++){out+=(Number(n&255n)).toString(16).padStart(2,'0');n>>=8n;}return out;
}
function reg(packet,index) {
    const match=new RegExp('(?:^|;)'+index+':([0-9a-f]{16});','i').exec(packet);
    if(!match)throw new Error('Missing register '+index);return fromLE(match[1]);
}
const pid=get_pid();
log('Attaching embedded Java JIT helper to '+pid);
const attached=send_command('vAttach;'+pid.toString(16));
if(!attached.startsWith('T'))throw new Error('Attach failed: '+attached);
while(true) {
    const stopped=send_command('c');
    if(stopped.startsWith('W')||stopped.startsWith('X'))break;
    const thread=/thread:([0-9a-f]+);/i.exec(stopped);
    if(!thread)throw new Error('No stopped thread: '+stopped);
    const tid=thread[1],pc=reg(stopped,'20');
    const instruction=Number(fromLE(send_command('m'+pc.toString(16)+',4')));
    if((instruction & 0xffe0001f) !== (0xd4200000|0))throw new Error('Unexpected non-BRK stop');
    const command=(instruction>>>5)&0xffff;
    if(command===0xf00d && reg(stopped,'10')===0n) {
        send_command('P20='+toLE(pc+4n)+';thread:'+tid+';');
        const detached=send_command('D');if(detached!=='OK')throw new Error('Detach failed: '+detached);
        log('Java cache initialized; embedded helper detached.');break;
    }
    if(command!==0x69)throw new Error('Unexpected BRK command '+command.toString(16));
    const bytes=reg(stopped,'00');
    const allocation=send_command('_M'+bytes.toString(16)+',rx');
    if(!/^[0-9a-f]+$/i.test(allocation)||allocation.startsWith('E'))throw new Error('Allocation failed: '+allocation);
    const address=BigInt('0x'+allocation);
    if(address===0n)throw new Error('Null executable mapping');
    log('Preparing '+bytes+' bytes for Java');
    const prepared=prepare_memory_region(address,bytes);
    log('Region preparation: '+prepared);
    if(prepared===false)throw new Error('Executable region preparation failed');
    if(send_command('P0='+toLE(address)+';thread:'+tid+';')!=='OK')throw new Error('Failed to return mapping');
    if(send_command('P20='+toLE(pc+4n)+';thread:'+tid+';')!=='OK')throw new Error('Failed to advance allocator');
}
