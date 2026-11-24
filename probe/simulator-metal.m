#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurfaceRef.h>
int main(void) { @autoreleasepool {
 id<MTLDevice> d = MTLCreateSystemDefaultDevice();
 NSLog(@"device %@",d.name);
 IOSurfaceRef s=IOSurfaceCreate((__bridge CFDictionaryRef)@{(__bridge id)kIOSurfaceWidth:@86,(__bridge id)kIOSurfaceHeight:@48,(__bridge id)kIOSurfaceBytesPerElement:@4,(__bridge id)kIOSurfaceBytesPerRow:@384,(__bridge id)kIOSurfaceAllocSize:@18432,(__bridge id)kIOSurfacePixelFormat:@((uint32_t)'BGRA')});
 if(!s)return 1;
 MTLTextureDescriptor *t=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:86 height:48 mipmapped:NO];
 t.storageMode=MTLStorageModeShared;t.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;
 id<MTLTexture> tex=[d newTextureWithDescriptor:t iosurface:s plane:0];
 NSLog(@"texture %@",tex);
 if(!tex)return 2;
 id<MTLCommandQueue> q=[d newCommandQueue];id<MTLCommandBuffer> cb=[q commandBuffer];
 MTLRenderPassDescriptor *p=[MTLRenderPassDescriptor renderPassDescriptor];p.colorAttachments[0].texture=tex;p.colorAttachments[0].loadAction=MTLLoadActionClear;p.colorAttachments[0].storeAction=MTLStoreActionStore;p.colorAttachments[0].clearColor=MTLClearColorMake(1,0,0,1);
 id<MTLRenderCommandEncoder> e=[cb renderCommandEncoderWithDescriptor:p];[e endEncoding];[cb commit];[cb waitUntilCompleted];
 IOSurfaceLock(s,kIOSurfaceLockReadOnly,NULL);unsigned char *pixels=IOSurfaceGetBaseAddress(s);NSLog(@"status %lu error %@ pixel %u %u %u %u",cb.status,cb.error,pixels[0],pixels[1],pixels[2],pixels[3]);int ok=pixels[2]==255 && pixels[3]==255;IOSurfaceUnlock(s,kIOSurfaceLockReadOnly,NULL);CFRelease(s);return ok?0:3;
}}
