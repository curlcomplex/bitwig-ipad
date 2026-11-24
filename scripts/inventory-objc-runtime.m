// Optional Simulator evidence for UIKit and Foundation method inheritance.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSArray *methods(Class owner, NSString *dispatch) {
    unsigned int count = 0;
    Method *list = class_copyMethodList(owner, &count);
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:count];
    for (unsigned int index = 0; index < count; index++) {
        [result addObject:@[dispatch, NSStringFromSelector(method_getName(list[index])),
                            @(method_getTypeEncoding(list[index]))]];
    }
    free(list);
    return result;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSMutableDictionary *classes = [NSMutableDictionary dictionary];
        for (int index = 1; index < argc; index++) {
            for (Class cls = NSClassFromString(@(argv[index])); cls; cls = class_getSuperclass(cls)) {
                NSString *name = NSStringFromClass(cls);
                if (classes[name]) break;
                Class parent = class_getSuperclass(cls);
                NSArray *declarations = [methods(cls, @"-") arrayByAddingObjectsFromArray:methods(object_getClass(cls), @"+")];
                classes[name] = @{@"superclass": parent ? NSStringFromClass(parent) : NSNull.null,
                                  @"methods": declarations};
            }
        }
        NSData *result = [NSJSONSerialization dataWithJSONObject:classes options:NSJSONWritingSortedKeys error:nil];
        [NSFileHandle.fileHandleWithStandardOutput writeData:result];
    }
}
