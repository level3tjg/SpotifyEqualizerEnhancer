TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = Spotify

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SpotifyEqualizerEnhancer

SpotifyEqualizerEnhancer_FILES = $(shell find Sources/SpotifyEqualizerEnhancer -name '*.swift') $(shell find Sources/SpotifyEqualizerEnhancerC -name '*.m' -o -name '*.c' -o -name '*.mm' -o -name '*.cpp')
SpotifyEqualizerEnhancer_SWIFTFLAGS = -ISources/SpotifyEqualizerEnhancerC/include
SpotifyEqualizerEnhancer_CFLAGS = -fobjc-arc -ISources/SpotifyEqualizerEnhancerC/include

include $(THEOS_MAKE_PATH)/tweak.mk
