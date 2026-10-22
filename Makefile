TARGET = iphone:clang:6.1:6.0
ARCHS = armv7

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SMSRelay
SMSRelay_FILES = Tweak.x
SMSRelay_FRAMEWORKS = Foundation UIKit
SMSRelay_LIBRARIES = substrate
SMSRelay_CFLAGS = -fobjc-arc

# The Settings pane is a plain PreferenceLoader plist (layout/Library/PreferenceLoader), no bundle.
include $(THEOS)/makefiles/tweak.mk
