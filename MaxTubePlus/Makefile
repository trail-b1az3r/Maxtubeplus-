# MaxTubePlus — Theos tweak injected next to YTPlus by the MaxTube workflows.
ARCHS = arm64
TARGET = iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = YouTube
MTP_VERSION ?= 1.0.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MaxTubePlus

$(TWEAK_NAME)_FILES = \
	Core/MTPCore.c \
	Common/MTPCommon.m Common/MTPVideoInfo.m Common/MTPContext.x \
	Downloads/MTPDownloadManager.m Downloads/MTPDownloadsViewController.m Downloads/Downloads.x \
	DeArrow/MTPDeArrowClient.m DeArrow/DeArrow.x \
	RefreshRate/RefreshRate.x \
	CreatorSuppression/MTPSuppressionStore.m CreatorSuppression/MTPSuppressedCreatorsViewController.m CreatorSuppression/CreatorSuppression.x \
	AdvancedSearch/MTPSearchFilterState.m AdvancedSearch/MTPSearchFilterViewController.m AdvancedSearch/MTPCommentHistory.m AdvancedSearch/MTPCommentedVideosViewController.m AdvancedSearch/AdvancedSearch.x \
	ModernUI/MTPTabLayout.m ModernUI/ModernUI.x \
	Settings/MTPSettingsViewController.m Settings/Settings.x \
	Tweak.x

$(TWEAK_NAME)_CFLAGS = -fobjc-arc -Wall -Werror -Wno-deprecated-declarations -Wno-unused-function -DMTP_VERSION=\"$(MTP_VERSION)\"
$(TWEAK_NAME)_CCFLAGS = -std=c99
$(TWEAK_NAME)_FRAMEWORKS = UIKit Foundation AVFoundation QuartzCore UserNotifications UniformTypeIdentifiers SafariServices CoreMedia
$(TWEAK_NAME)_LOGOS_DEFAULT_GENERATOR = internal

include $(THEOS_MAKE_PATH)/tweak.mk
