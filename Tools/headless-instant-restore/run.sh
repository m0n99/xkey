#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
mkdir -p build/headless-instant-restore
swiftc \
    Shared/InputSession/CaretWordRecovery.swift \
    Shared/CaretWordAXReader.swift \
    XKey/Core/Models/VNCharacter.swift \
    XKey/Core/Models/VNCharacterMap.swift \
    XKey/Core/Models/VowelSequenceValidator.swift \
    XKey/Core/Engine/VietnameseData.swift \
    XKey/Core/Engine/TypingBuffer.swift \
    XKey/Core/Engine/VNEngine.swift \
    XKey/Core/Engine/VNEngineAdvanced.swift \
    XKey/Core/Engine/VNEngineEnglishDetection.swift \
    XKey/Core/Engine/VNEngineMacro.swift \
    XKey/Core/Engine/VNEngineSpellCheck.swift \
    Tools/headless-recovery/Stubs.swift \
    Tools/headless-instant-restore/RimeScenarios.swift \
    Tools/headless-instant-restore/StructuralScenarios.swift \
    Tools/headless-instant-restore/main.swift \
    -o build/headless-instant-restore/run
exec build/headless-instant-restore/run
