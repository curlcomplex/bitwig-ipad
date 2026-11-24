// Prepare existing code pages without changing their contents or addresses.
function fromLE(hex){let n=0n;for(let i=hex.length-2;i>=0;i-=2)n=(n<<8n)|BigInt('0x'+hex.slice(i,i+2));return n;}
function toLE(n){let out='';for(let i=0;i<8;i++){out+=Number(n&255n).toString(16).padStart(2,'0');n>>=8n;}return out;}
function reg(packet,index){const m=new RegExp('(?:^|;)'+index+':([0-9a-f]{16});','i').exec(packet);if(!m)throw Error('Missing register '+index);return fromLE(m[1]);}
const pid=get_pid();
const attached=send_command('vAttach;'+pid.toString(16));
if(!attached.startsWith('T'))throw Error('Engine attach failed: '+attached);
log('Serving original-address engine JIT for pid '+pid);
let prepared=0,lastRegion='';
while(true){
    const stopped=send_command('c');
    if(stopped.startsWith('W')||stopped.startsWith('X'))break;
    const thread=/thread:([0-9a-f]+);/i.exec(stopped);if(!thread)throw Error('No stopped engine thread: '+stopped);
    const tid=thread[1],pc=reg(stopped,'20');
    const instruction=Number(fromLE(send_command('m'+pc.toString(16)+',4')));
    const command=(instruction>>>5)&0xffff;
    if((instruction&0xffe0001f)!==(0xd4200000|0)||![0x71,0x72].includes(command))
        throw Error('Unexpected engine stop after '+prepared+' preparations; '+lastRegion+'; '+stopped+' instruction='+instruction.toString(16));
    if(command===0x72){
        const bytes=reg(stopped,'00');
        const allocated=send_command('_M'+bytes.toString(16)+',rx');
        if(!/^[0-9a-f]+$/i.test(allocated)||allocated.startsWith('E'))throw Error('Debugger RX allocation failed: '+allocated);
        const address=BigInt('0x'+allocated);
        if(prepare_memory_region(address,bytes)!=='OK')throw Error('RX preparation failed');
        lastRegion='allocated '+send_command('qMemoryRegionInfo:'+address.toString(16));
        if(send_command('P0='+toLE(address)+';thread:'+tid+';')!=='OK')throw Error('Cannot return allocation');
        if(send_command('P20='+toLE(pc+4n)+';thread:'+tid+';')!=='OK')throw Error('Cannot resume allocation');
        continue;
    }
    const address=reg(stopped,'00'),length=reg(stopped,'01');
    for(let page=address;page<address+length;page+=16384n){
        const old=send_command('m'+page.toString(16)+',1');
        if(!/^[0-9a-f]{2}$/i.test(old))throw Error('Cannot read code page '+page.toString(16)+': '+old);
        const marker=(parseInt(old,16)^255).toString(16).padStart(2,'0');
        if(send_command('M'+page.toString(16)+',1:'+marker)!=='OK')throw Error('Cannot mark code page');
        const wrote=send_command('M'+page.toString(16)+',1:'+old);
        if(wrote!=='OK')throw Error('Cannot prepare code page '+page.toString(16)+': '+wrote);
    }
    prepared++;lastRegion=send_command('qMemoryRegionInfo:'+address.toString(16));
    if(send_command('P0='+toLE(0n)+';thread:'+tid+';')!=='OK')throw Error('Cannot return finalization result');
    if(send_command('P20='+toLE(pc+4n)+';thread:'+tid+';')!=='OK')throw Error('Cannot resume finalization');
}
log('Native engine exited; JIT service finished');
