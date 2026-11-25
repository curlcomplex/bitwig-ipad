#pragma once
#import <UIKit/UIKit.h>

// USB HID usages identify physical positions. The original Bitwig JNI expects
// Carbon virtual key codes and separately consumes UIKit's layout-aware text.
static inline NSInteger BWMacVirtualKey(UIKeyboardHIDUsage usage) {
    static const int8_t letters[] = {
        0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6
    };
    static const int8_t digits[] = {18, 19, 20, 21, 23, 22, 26, 28, 25, 29};
    static const int8_t basic[] = {
        // Return, Escape, Backspace, Tab, Space, punctuation, Caps Lock.
        36, 53, 51, 48, 49, 27, 24, 33, 30, 42, 42, 41, 39, 50, 43, 47, 44, 57
    };
    static const int8_t functions[] = {122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111};
    static const int8_t navigation[] = {114, 115, 116, 117, 119, 121, 124, 123, 125, 126};
    static const int8_t keypad[] = {71, 75, 67, 78, 69, 76, 83, 84, 85, 86, 87, 88, 89, 91, 92, 82, 65};
    static const int8_t extraFunctions[] = {105, 107, 113, 106, 64, 79, 80, 90};
    static const int8_t modifiers[] = {59, 56, 58, 55, 62, 60, 61, 54};
    if (usage >= UIKeyboardHIDUsageKeyboardA && usage <= UIKeyboardHIDUsageKeyboardZ)
        return letters[usage - UIKeyboardHIDUsageKeyboardA];
    if (usage >= UIKeyboardHIDUsageKeyboard1 && usage <= UIKeyboardHIDUsageKeyboard0)
        return digits[usage - UIKeyboardHIDUsageKeyboard1];
    if (usage >= UIKeyboardHIDUsageKeyboardReturnOrEnter && usage <= UIKeyboardHIDUsageKeyboardCapsLock)
        return basic[usage - UIKeyboardHIDUsageKeyboardReturnOrEnter];
    if (usage >= UIKeyboardHIDUsageKeyboardF1 && usage <= UIKeyboardHIDUsageKeyboardF12)
        return functions[usage - UIKeyboardHIDUsageKeyboardF1];
    if (usage >= UIKeyboardHIDUsageKeyboardInsert && usage <= UIKeyboardHIDUsageKeyboardUpArrow)
        return navigation[usage - UIKeyboardHIDUsageKeyboardInsert];
    if (usage >= UIKeyboardHIDUsageKeypadNumLock && usage <= UIKeyboardHIDUsageKeypadPeriod)
        return keypad[usage - UIKeyboardHIDUsageKeypadNumLock];
    if (usage >= UIKeyboardHIDUsageKeyboardF13 && usage <= UIKeyboardHIDUsageKeyboardF20)
        return extraFunctions[usage - UIKeyboardHIDUsageKeyboardF13];
    if (usage >= UIKeyboardHIDUsageKeyboardLeftControl && usage <= UIKeyboardHIDUsageKeyboardRightGUI)
        return modifiers[usage - UIKeyboardHIDUsageKeyboardLeftControl];
    switch (usage) {
        case UIKeyboardHIDUsageKeyboardNonUSBackslash: return 10;
        case UIKeyboardHIDUsageKeypadEqualSign: return 81;
        case UIKeyboardHIDUsageKeyboardHelp: return 114;
        default: return -1;
    }
}

static inline NSUInteger BWKeyModifier(UIKeyboardHIDUsage usage) {
    static const NSUInteger flags[] = {
        UIKeyModifierControl, UIKeyModifierShift, UIKeyModifierAlternate, UIKeyModifierCommand
    };
    if (usage >= UIKeyboardHIDUsageKeyboardLeftControl && usage <= UIKeyboardHIDUsageKeyboardRightGUI)
        return flags[(usage - UIKeyboardHIDUsageKeyboardLeftControl) % 4];
    return 0;
}
