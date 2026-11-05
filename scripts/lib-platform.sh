#!/bin/bash

platform_detect() {
  case "$(uname -s)" in
    Darwin) PLATFORM_OS="macos" ;;
    Linux)
      if grep -qi microsoft /proc/version 2>/dev/null; then
        PLATFORM_OS="windows-wsl2"
      else
        PLATFORM_OS="linux"
      fi
      ;;
    *) PLATFORM_OS="unknown" ;;
  esac
}

platform_is_macos()        { [ "$PLATFORM_OS" = "macos" ]; }
platform_is_wsl2()         { [ "$PLATFORM_OS" = "windows-wsl2" ]; }
platform_is_linux_native() { [ "$PLATFORM_OS" = "linux" ]; }

platform_detect
