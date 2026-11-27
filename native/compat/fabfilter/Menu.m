#import "Menu.h"

@interface BWFabFilterMenuController : UITableViewController <UIPopoverPresentationControllerDelegate>
@property(nonatomic, copy) NSArray<NSDictionary *> *items;
@property(nonatomic, strong) NSMutableArray<NSArray<NSDictionary *> *> *parents;
@property(nonatomic, copy) void (^reply)(NSInteger);
- (void)finish:(NSInteger)selection;
@end

@implementation BWFabFilterMenuController
- (void)finish:(NSInteger)selection {
    void (^reply)(NSInteger) = self.reply;
    self.reply = nil;
    if (!reply) return;
    if (self.presentingViewController) {
        [self dismissViewControllerAnimated:NO completion:^{ reply(selection); }];
    } else {
        reply(selection);
    }
}
- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    [self finish:-1];
}
- (BOOL)accessibilityPerformEscape {
    [self finish:-1];
    return YES;
}
- (BOOL)canBecomeFirstResponder { return YES; }
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self becomeFirstResponder];
}
- (NSArray<UIKeyCommand *> *)keyCommands {
    return @[[UIKeyCommand keyCommandWithInput:UIKeyInputEscape modifierFlags:0 action:@selector(cancelMenu:)]];
}
- (void)cancelMenu:(id)sender { [self finish:-1]; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.items.count + (self.parents.count > 0);
}
- (NSDictionary *)itemAtRow:(NSInteger)row {
    if (!self.parents.count) return self.items[row];
    return row ? self.items[row - 1] : nil;
}
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)path {
    return [self itemAtRow:path.row][@"separator"] ? 10 : 44;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    NSDictionary *item = [self itemAtRow:path.row];
    if (!item) {
        cell.textLabel.text = @"Back";
        cell.imageView.image = [UIImage systemImageNamed:@"chevron.left"];
    } else if (item[@"separator"]) {
        cell.isAccessibilityElement = NO;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        cell.textLabel.text = item[@"title"];
        NSInteger state = [item[@"state"] integerValue];
        if (state) cell.imageView.image = [UIImage systemImageNamed:state > 0 ? @"checkmark" : @"minus"];
        if (state > 0) cell.accessibilityTraits |= UIAccessibilityTraitSelected;
        if (state < 0) cell.accessibilityValue = @"Mixed";
        if ([item[@"children"] count]) cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        if (![item[@"enabled"] boolValue]) {
            cell.textLabel.enabled = NO;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.accessibilityTraits |= UIAccessibilityTraitNotEnabled;
        }
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:NO];
    NSDictionary *item = [self itemAtRow:path.row];
    if (!item) {
        self.items = self.parents.lastObject;
        [self.parents removeLastObject];
    } else if ([item[@"enabled"] boolValue] && !item[@"separator"]) {
        if (![item[@"children"] count]) {
            [self finish:[item[@"index"] integerValue]];
            return;
        }
        [self.parents addObject:self.items];
        self.items = item[@"children"];
    } else {
        return;
    }
    [tableView reloadData];
    [tableView setContentOffset:CGPointZero animated:NO];
}
@end

UIViewController *BWPresentFabFilterMenu(UIView *source, CGPoint normalizedAnchor,
                                        NSArray<NSDictionary *> *items, NSNumber *positioningItem,
                                        void (^reply)(NSInteger)) {
    UIWindow *window = source.window;
    UIViewController *presenter = window.rootViewController;
    if (!presenter || presenter.presentedViewController ||
        window.windowScene.activationState != UISceneActivationStateForegroundActive ||
        CGRectIsEmpty(source.bounds) || !items.count) return nil;

    BWFabFilterMenuController *menu = [BWFabFilterMenuController new];
    menu.items = items;
    menu.parents = [NSMutableArray new];
    menu.reply = reply;
    menu.view.accessibilityViewIsModal = YES;
    menu.modalPresentationStyle = UIModalPresentationPopover;
    menu.preferredContentSize = CGSizeMake(250, MIN(440, items.count * 44));
    UIPopoverPresentationController *popover = menu.popoverPresentationController;
    popover.delegate = menu;
    popover.sourceView = source;
    popover.sourceRect = CGRectMake(CGRectGetMinX(source.bounds) + normalizedAnchor.x * CGRectGetWidth(source.bounds),
                                   CGRectGetMinY(source.bounds) + normalizedAnchor.y * CGRectGetHeight(source.bounds), 1, 1);
    [presenter presentViewController:menu animated:NO completion:^{
        if (!positioningItem) return;
        NSUInteger row = [items indexOfObjectPassingTest:^BOOL(NSDictionary *item, NSUInteger index, BOOL *stop) {
            return [item[@"index"] isEqualToNumber:positioningItem];
        }];
        if (row != NSNotFound && items.count > 10)
            [menu.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]
                                 atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
    }];
    return menu;
}
