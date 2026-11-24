#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
int main(void) { @autoreleasepool {
 id d=MTLCreateSystemDefaultDevice();NSLog(@"device %@",[d class]);
 for(Class c=object_getClass(d);c;c=class_getSuperclass(c)) {
  unsigned n;Ivar *iv=class_copyIvarList(c,&n);
  for(unsigned i=0;i<n;i++)NSLog(@"ivar %@ %s %s",NSStringFromClass(c),ivar_getName(iv[i]),ivar_getTypeEncoding(iv[i]));free(iv);
  Method *m=class_copyMethodList(c,&n);
  for(unsigned i=0;i<n;i++){NSString *s=NSStringFromSelector(method_getName(m[i]));if([s.lowercaseString containsString:@"device"]||[s.lowercaseString containsString:@"real"]||[s.lowercaseString containsString:@"underlying"])NSLog(@"method %@ %@",NSStringFromClass(c),s);}free(m);
 }
 return 0;
}}
