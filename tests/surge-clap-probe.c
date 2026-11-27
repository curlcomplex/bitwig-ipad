#include <clap/clap.h>
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef SURGE_EDITOR
extern const clap_plugin_entry_t *BWEditorEntry(const clap_plugin_entry_t *entry);
extern bool probe_editor(const clap_plugin_t *plugin);
#endif

static const void *CLAP_ABI extension(const clap_host_t *host, const char *id) { return NULL; }
static void CLAP_ABI request(const clap_host_t *host) {}

static clap_event_note_t note = {
    .header = {.size=sizeof(note), .type=CLAP_EVENT_NOTE_ON, .space_id=CLAP_CORE_EVENT_SPACE_ID},
    .note_id=10, .key=60, .channel=0, .port_index=0, .velocity=0.8,
};
static uint32_t CLAP_ABI event_count(const clap_input_events_t *list) { return list->ctx ? 1 : 0; }
static const clap_event_header_t *CLAP_ABI get_event(const clap_input_events_t *list, uint32_t index) {
    return !index ? list->ctx : NULL;
}
static bool CLAP_ABI push_event(const clap_output_events_t *list, const clap_event_header_t *event) { return true; }

struct state_buffer { uint8_t *bytes; size_t size, read; };
static int64_t CLAP_ABI write_state(const clap_ostream_t *stream,const void *data,uint64_t size) {
    struct state_buffer *buf=stream->ctx;
    uint8_t *bytes=realloc(buf->bytes,buf->size+size);
    if(!bytes)return -1;
    buf->bytes=bytes;
    memcpy(bytes+buf->size,data,size);
    buf->size+=size;
    return size;
}
static int64_t CLAP_ABI read_state(const clap_istream_t *stream,void *data,uint64_t size) {
    struct state_buffer *buf=stream->ctx;
    if(size>buf->size-buf->read)size=buf->size-buf->read;
    memcpy(data,buf->bytes+buf->read,size);
    buf->read+=size;
    return size;
}

static bool verify_state(const clap_plugin_t *plugin,const clap_plugin_params_t *params,const clap_output_events_t *events) {
    const clap_plugin_state_t *state=plugin->get_extension(plugin,CLAP_EXT_STATE);
    if(!params||!state)return false;
    for(uint32_t i=0;i<params->count(plugin);i++) {
        clap_param_info_t info;
        if(!params->get_info(plugin,i,&info) || (info.flags&(CLAP_PARAM_IS_READONLY|CLAP_PARAM_IS_STEPPED)) ||
            !(info.flags&CLAP_PARAM_IS_AUTOMATABLE))continue;
        double initial;
        if(!params->get_value(plugin,info.id,&initial)||info.max_value<=info.min_value)continue;
        clap_event_param_value_t change={.header={.size=sizeof(change),.type=CLAP_EVENT_PARAM_VALUE,.space_id=CLAP_CORE_EVENT_SPACE_ID},
            .param_id=info.id,.cookie=info.cookie,.note_id=-1,.port_index=-1,.channel=-1,.key=-1,
            .value=info.min_value+(info.max_value-info.min_value)*0.19};
        const clap_input_events_t input={.ctx=&change,.size=event_count,.get=get_event};
        params->flush(plugin,&input,events);
        double changed;
        if(!params->get_value(plugin,info.id,&changed)||fabs(initial-changed)<1e-5)continue;
        struct state_buffer buf={0};
        const clap_ostream_t output={.ctx=&buf,.write=write_state};
        const clap_istream_t saved={.ctx=&buf,.read=read_state};
        if(!state->save(plugin,&output)||!buf.size){free(buf.bytes);return false;}
        change.value=initial;
        params->flush(plugin,&input,events);
        double mutated,restored;
        bool ok=params->get_value(plugin,info.id,&mutated)&&fabs(mutated-changed)>1e-5 &&
            state->load(plugin,&saved)&&params->get_value(plugin,info.id,&restored)&&fabs(restored-changed)<1e-5;
        if(ok)fprintf(stderr,"SURGE_STATE %s %zu bytes; %.7f -> %.7f -> %.7f\n",info.name,buf.size,changed,mutated,restored);
        free(buf.bytes);
        return ok;
    }
    return false;
}

int probe_surge(const char *binary, const char *bundle) {
    void *library=dlopen(binary, RTLD_NOW | RTLD_LOCAL);
    if (!library) { fprintf(stderr, "SURGE_LOAD %s\n", dlerror()); return 1; }
    const clap_plugin_entry_t *entry=dlsym(library,"clap_entry");
#ifdef SURGE_EDITOR
    entry=BWEditorEntry(entry);
#endif
    if (!entry || !entry->init(bundle)) { fprintf(stderr, "SURGE_ENTRY failed\n"); return 2; }
    const clap_plugin_factory_t *factory=entry->get_factory(CLAP_PLUGIN_FACTORY_ID);
    const clap_plugin_descriptor_t *desc=factory && factory->get_plugin_count(factory) ? factory->get_plugin_descriptor(factory,0) : NULL;
    if (!desc) { fprintf(stderr, "SURGE_FACTORY failed\n"); return 3; }
    const clap_host_t host={.clap_version=CLAP_VERSION_INIT,.name="Surge CLAP Probe",.vendor="Local test",.url="https://example.invalid",.version="1",
        .get_extension=extension,.request_restart=request,.request_process=request,.request_callback=request};
    fprintf(stderr, "SURGE_DESCRIPTOR %s %s %s\n",desc->id,desc->name,desc->version);
    const clap_plugin_t *plugin=factory->create_plugin(factory,&host,desc->id);
    if (!plugin || !plugin->init(plugin)) { fprintf(stderr, "SURGE_PLUGIN_INIT failed\n"); return 4; }
#ifdef SURGE_HEADLESS
    if (plugin->get_extension(plugin,CLAP_EXT_GUI)) return 11;
    fprintf(stderr,"SURGE_HEADLESS gui unavailable\n");
#endif
#ifdef SURGE_EDITOR
    if (!probe_editor(plugin)) return 12;
#endif
#ifdef CHOW_EDITOR
    plugin->destroy(plugin);
    entry->deinit();
    return 0;
#endif
    const clap_plugin_params_t *params=plugin->get_extension(plugin,CLAP_EXT_PARAMS);
    fprintf(stderr,"SURGE_PARAMS %u\n",params ? params->count(plugin) : 0);
    const clap_output_events_t events={.try_push=push_event};
    if(!verify_state(plugin,params,&events))return 9;
    const clap_plugin_audio_ports_t *ports=plugin->get_extension(plugin,CLAP_EXT_AUDIO_PORTS);
    clap_audio_port_info_t port;
    if (!ports || !ports->get(plugin,0,false,&port) || port.channel_count!=2 ||
        !plugin->activate(plugin,48000,64,64) || !plugin->start_processing(plugin)) return 5;
    float left[64]={0}, right[64]={0};
    float *channels[]={left,right};
    clap_audio_buffer_t output={.data32=channels,.channel_count=2};
    clap_input_events_t input={.ctx=&note,.size=event_count,.get=get_event};
    clap_process_t process={.frames_count=64,.audio_outputs=&output,.audio_outputs_count=1,.in_events=&input,.out_events=&events};
    double peak=0;
    for (int i=0;i<128;i++) {
        if (plugin->process(plugin,&process)==CLAP_PROCESS_ERROR) return 6;
        input.ctx=NULL;
        process.steady_time+=64;
        for (int j=0;j<64;j++) {
            if (!isfinite(left[j]) || !isfinite(right[j])) return 7;
            peak=fmax(peak,fmax(fabs(left[j]),fabs(right[j])));
        }
    }
    note.header.type=CLAP_EVENT_NOTE_OFF;
    input.ctx=&note;
    double release_peak=0;
    for(int i=0;i<3000;i++) {
        if(plugin->process(plugin,&process)==CLAP_PROCESS_ERROR)return 10;
        input.ctx=NULL;
        process.steady_time+=64;
        for(int j=0;j<64;j++) {
            if(!isfinite(left[j])||!isfinite(right[j]))return 10;
            if(i>=2940)release_peak=fmax(release_peak,fmax(fabs(left[j]),fabs(right[j])));
        }
    }
    fprintf(stderr,"SURGE_RENDER peak=%.8f release_tail_peak=%.8f\n",peak,release_peak);
    plugin->stop_processing(plugin);
    plugin->deactivate(plugin);
    plugin->destroy(plugin);
    entry->deinit();
#ifndef SURGE_EDITOR
    // An editor registers Objective-C classes whose implementations remain
    // reachable from UIKit until process shutdown.
    dlclose(library);
#endif
    if(peak<=0 || release_peak>=peak*0.01) return 8;
    fprintf(stderr,"SURGE_PASS\n");
    return 0;
}

#ifdef SURGE_STANDALONE
int main(int argc, char **argv) { return argc==3 ? probe_surge(argv[1],argv[2]) : 64; }
#endif
