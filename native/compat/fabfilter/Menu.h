#import <UIKit/UIKit.h>

BOOL BWRunFabFilterMenu(UIView *view, CGPoint point, NSArray<NSDictionary *> *items,
                        NSNumber *positioningItem, NSInteger *selection);
UIViewController *BWPresentFabFilterMenu(UIView *source, CGPoint normalizedAnchor,
                                        NSArray<NSDictionary *> *items, NSNumber *positioningItem,
                                        void (^reply)(NSInteger selection));
