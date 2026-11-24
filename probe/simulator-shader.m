#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "metallib.h"
int main(int argc,char **argv) { @autoreleasepool {
 if(argc!=2)return 1;
 NSMutableData *bytes=[[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]] mutableCopy];
 int changes=hv_metallib_relabel(bytes.mutableBytes,bytes.length,2);
 id<MTLDevice> d=MTLCreateSystemDefaultDevice();NSError *error=nil;
 dispatch_data_t dd=dispatch_data_create(bytes.bytes,bytes.length,NULL,DISPATCH_DATA_DESTRUCTOR_DEFAULT);
 id<MTLLibrary> lib=[d newLibraryWithData:dd error:&error];NSLog(@"relabel changes %d library %@ error %@",changes,lib,error);
 if(!lib)return 2;
 id<MTLFunction> fn=[lib newFunctionWithName:lib.functionNames.firstObject];
 if(fn.functionType==MTLFunctionTypeVertex) {
  MTLRenderPipelineDescriptor *rd=[MTLRenderPipelineDescriptor new];rd.vertexFunction=fn;rd.rasterizationEnabled=YES;rd.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;
  MTLVertexDescriptor *vd=[MTLVertexDescriptor vertexDescriptor];
  for(MTLVertexAttribute *a in fn.vertexAttributes) { if(!a.active)continue;NSLog(@"attribute %@ %lu type %lu",a.name,a.attributeIndex,a.attributeType);vd.attributes[a.attributeIndex].format=MTLVertexFormatFloat4;vd.attributes[a.attributeIndex].offset=a.attributeIndex*16;vd.attributes[a.attributeIndex].bufferIndex=30; }
  vd.layouts[30].stride=256;rd.vertexDescriptor=vd;
  id<MTLRenderPipelineState> rp=[d newRenderPipelineStateWithDescriptor:rd error:&error];NSLog(@"guest vertex pipeline %@ error %@",rp,error);return rp?0:5;
 }
 id<MTLComputePipelineState> pipe=[d newComputePipelineStateWithFunction:fn error:&error];NSLog(@"pipeline %@ error %@",pipe,error);
 if(!pipe)return 3;
 id<MTLBuffer> buf=[d newBufferWithLength:256 options:MTLResourceStorageModeShared];
 id<MTLCommandQueue> q=[d newCommandQueue];id<MTLCommandBuffer> cb=[q commandBuffer];id<MTLComputeCommandEncoder> e=[cb computeCommandEncoder];[e setComputePipelineState:pipe];[e setBuffer:buf offset:0 atIndex:0];[e dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];[e endEncoding];[cb commit];[cb waitUntilCompleted];
 unsigned result=*(unsigned *)buf.contents;NSLog(@"result %u error %@",result,cb.error);return result==42?0:4;
}}
