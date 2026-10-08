[CmdletBinding()]
param(
    [string]$OwnedDataRoot = $env:SKATE3_OWNED_DATA_ROOT,
    [string]$Blender = $env:BLENDER_EXECUTABLE,
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$OutputStem = 'skater_push',
    [string]$Rx2Source = '',
    [string]$PostProcessScript = '',
    [string[]]$PostProcessArguments = @()
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Blender)) {
    $Blender = 'C:\Program Files\Blender Foundation\Blender 5.1\blender.exe'
}
$ProjectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OwnedDataRoot)) {
    $OwnedDataRoot = Join-Path $ProjectRoot 'work\private-assets\owned-game'
}
$SourceAbin = Join-Path $OwnedDataRoot 'data\anim\OnBoard.abin'
$OffboardAbin = Join-Path $OwnedDataRoot 'data\anim\OffBoard.abin'
$OnboardCatalog = Join-Path $OwnedDataRoot 'generated\skate3_onboard_clips.csv'
$StateGraphRoot = Join-Path $OwnedDataRoot 'data\state'
$ActionGraphRoot = Join-Path $StateGraphRoot 'ActionGraphIncludes'
$MotionGraphRoot = Join-Path $StateGraphRoot 'MotionGraphIncludes'
$MotionGraphOnBoard = Join-Path $StateGraphRoot 'MotionGraph_OnBoard.xml'
$SourceRx2 = if ($Rx2Source) {
    [IO.Path]::GetFullPath($Rx2Source)
}
else {
    Join-Path $ProjectRoot 'work\private-assets\default_skater\selected\models'
}
$ImporterDir = Join-Path $ProjectRoot 'tools\vendor\skate3_anim'
$Exporter = Join-Path $ImporterDir 'blender_rx2_abin_export.py'
$GlbExporter = Join-Path $PSScriptRoot 'export_bevy_glb.py'
$TargetExporter = Join-Path $PSScriptRoot 'add_onboard_ik_targets.py'
$FakieWeightVerifier = Join-Path $PSScriptRoot 'verify_fakie_channel_weights.py'
$RetailFakieExporter = Join-Path $PSScriptRoot 'add_retail_fakie_composite_action.py'
$MirroredOnboardExporter = Join-Path $PSScriptRoot 'add_mirrored_onboard_actions.py'
$CombinedFlipExporter = Join-Path $PSScriptRoot 'add_combined_flip_actions.py'
$GlbFootTargetValidator = Join-Path $PSScriptRoot 'assert_glb_foot_targets.py'
$Glb360FlipPoseValidator = Join-Path $PSScriptRoot 'assert_glb_360_flip_pose.py'
$GlbFlipInPoseValidator = Join-Path $PSScriptRoot 'assert_glb_flip_in_pose.py'
$PrivateDir = Join-Path $ProjectRoot 'assets\private'
$WorkDir = Join-Path $ProjectRoot 'work\private-assets'
$Blend = Join-Path $WorkDir 'skater_push_source.blend'
$Glb = Join-Path $PrivateDir "$OutputStem.glb"
$Manifest = Join-Path $PrivateDir "$OutputStem.manifest.txt"
$RootMotion = Join-Path $PrivateDir "$OutputStem.root_motion.json"
$Validation = Join-Path $WorkDir 'skater_push_source.validation.json'
$Evidence = Join-Path $WorkDir 'skater_push_source.evidence.json'

function Get-Sha256Hash {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath
    )

    $resolved = [IO.Path]::GetFullPath($LiteralPath)
    $stream = [IO.File]::OpenRead($resolved)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha256.ComputeHash($stream)
        return [PSCustomObject]@{
            Hash = [BitConverter]::ToString($bytes).Replace('-', '')
        }
    }
    finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}

$graphEvidence = @(
    [ordered]@{
        path = Join-Path $MotionGraphRoot 'Anticipations\AnticInto.xml'
        virtual_references = @('B_ANTIC_INTO', 'B_N_ANTIC_INTO')
    },
    [ordered]@{
        path = Join-Path $MotionGraphRoot 'Anticipations\AnticCyc.xml'
        virtual_references = @(
            'B_ANTIC_CYC',
            'B_ANTIC_360SHUVIT_CYC',
            'B_ANTIC_FS360SHUVIT_CYC',
            'B_N_ANTIC_CYC',
            'B_ANTIC_N360SHUVIT_CYC',
            'B_ANTIC_NFS360SHUVIT_CYC'
        )
    },
    [ordered]@{
        path = Join-Path $MotionGraphRoot 'Anticipations\AnticOut.xml'
        virtual_references = @('B_ANTIC_OUT', 'B_N_ANTIC_OUT')
    },
    [ordered]@{
        path = Join-Path $MotionGraphRoot 'ground.xml'
        virtual_references = @(
            'MongoPushToAntic',
            'MONGO_PUSH_TO_ANTIC',
            'MONGO_PUSH_TO_NANTIC',
            'OverideNextAnimTransitionHook',
            'time="0.2"'
        )
    },
    [ordered]@{
        path = Join-Path $MotionGraphRoot 'Tricks\Tricks.xml'
        virtual_references = @(
            'ANIM_NAME="B_OLLIE"',
            'ANIM_NAME="B_NOLLIE"',
            'BS_SPIN_ANIM="IA_BODYSPIN_OLLIE_BS_0_N"',
            'FS_SPIN_ANIM="IA_BODYSPIN_OLLIE_FS_0_N"'
        )
    },
    [ordered]@{
        path = Join-Path $MotionGraphRoot 'Tricks\T_Ollie.xml'
        virtual_references = @('$ANIM_NAME$_G', '$ANIM_NAME$_A')
    },
    [ordered]@{
        path = Join-Path $MotionGraphRoot 'Tricks\T_Kickflip.xml'
        virtual_references = @(
            '$ANIM_CYC_NAME$1',
            '$ANIM_CYC_NAME$2',
            '$ANIM_CYC_NAME$3',
            '$ANIM_OUT_NAME$1',
            '$ANIM_OUT_NAME$2',
            '$ANIM_OUT_NAME$3',
            '$ANIM_OUT_NAME$4',
            '$TRICK_NAME$Hold'
        )
    },
    [ordered]@{
        path = Join-Path $MotionGraphRoot 'air.xml'
        virtual_references = @('B_AIR_CYC')
    },
    [ordered]@{
        path = Join-Path $MotionGraphRoot 'Landing.xml'
        virtual_references = @(
            'BLEND_LAND',
            'B_LAND_NICE',
            'B_LAND_SKETCH',
            'numlandings="3"',
            'numlandings="5"'
        )
    },
    [ordered]@{
        path = Join-Path $MotionGraphRoot 'GroundGrabs\FSGrab.xml'
        virtual_references = @('BLEND_FSGRAB_INTO', 'BLEND_FSGRAB', 'BLEND_FS2DBL_TR', 'B_FSGRAB_OUT')
    },
    [ordered]@{
        path = Join-Path $MotionGraphRoot 'GroundGrabs\BSGrab.xml'
        virtual_references = @('BLEND_BSGRAB_INTO', 'BLEND_BSGRAB', 'BLEND_BS2DBL_TR', 'B_BSGRAB_OUT')
    },
    [ordered]@{
        path = Join-Path $MotionGraphRoot 'GroundGrabs\DBLGrab.xml'
        virtual_references = @('BLEND_DBLGRAB_INTO', 'BLEND_DBLGRAB', 'BLEND_DBL2FS_TR', 'BLEND_DBL2BS_TR', 'B_DBLGRAB_OUT')
    },
    [ordered]@{
        path = Join-Path $ActionGraphRoot 'air.xml'
        virtual_references = @('LeftAirGrab', 'RightAirGrab', 'BoardAdjustUp', 'BoardAdjustDown')
    },
    [ordered]@{
        path = Join-Path $ActionGraphRoot 'T_Grab.xml'
        virtual_references = @('LeftPush', 'RightPush', 'Dismount')
    },
    [ordered]@{
        path = Join-Path $ActionGraphRoot 'StaleMuteGrab.xml'
        virtual_references = @('StaleGrab', 'MuteGrab')
    },
    [ordered]@{
        path = Join-Path $ActionGraphRoot 'BoardAdjustUp.xml'
        virtual_references = @(
            'intent="BoardAdjustAngle"',
            'abs="true"',
            'greaterEqual="2.355"'
        )
    },
    [ordered]@{
        path = Join-Path $ActionGraphRoot 'BoardAdjustDown.xml'
        virtual_references = @(
            'intent="BoardAdjustAngle"',
            'abs="true"',
            'lessEqual="0.785"'
        )
    },
    [ordered]@{
        path = Join-Path $ActionGraphRoot 'BoardAdjustLeft.xml'
        virtual_references = @(
            'lessEqual="-0.785"',
            'greaterEqual="-2.355"'
        )
    },
    [ordered]@{
        path = Join-Path $ActionGraphRoot 'BoardAdjustRight.xml'
        virtual_references = @(
            'lessEqual="2.355"',
            'greaterEqual="0.785"'
        )
    },
    [ordered]@{
        path = Join-Path $ActionGraphRoot 'coffin.xml'
        virtual_references = @('Coffin', 'LeftAirGrab', 'RightAirGrab')
    },
    [ordered]@{
        path = Join-Path $ActionGraphRoot 'superman.xml'
        virtual_references = @('Superman', 'Dismount')
    },
    [ordered]@{
        path = Join-Path $MotionGraphRoot 'GrabsTweaks\T_FSBSGrab.xml'
        virtual_references = @(
            'anim="$ANIM_INTO$"',
            'anim="$ANIM_CYC$"',
            'filteredIntent="TweakX"',
            'filteredIntent="TweakY"'
        )
    },
    [ordered]@{
        path = Join-Path $MotionGraphRoot 'GrabsTweaks\T_MuteStaleGrab.xml'
        virtual_references = @(
            'anim="$ANIM_INTO$"',
            'anim="$ANIM_CYC$"',
            'greaterEqual="0.2"'
        )
    },
    [ordered]@{
        path = Join-Path $MotionGraphRoot 'GrabsTweaks\DBLGrab.xml'
        virtual_references = @('BLEND_DBL_TWEAK')
    },
    [ordered]@{
        path = Join-Path $MotionGraphRoot 'GrabsTweaks\Superman.xml'
        virtual_references = @(
            'GR_DSMNT_SUPER_DBL_0_INTO',
            'GR_DSMNT_SUPER_DBL_0_CYC',
            'GR_DSMNT_N_SUPER_TO_CHRIST'
        )
    },
    [ordered]@{
        path = Join-Path $MotionGraphRoot 'GrabsTweaks\T_1FtAir.xml'
        virtual_references = @(
            '1FT_AIR_GRAB_N_$ANIM_SPECIFIER$_0_INTO',
            '1FT_AIR_GRAB_N_$ANIM_SPECIFIER$_0_CYC',
            'T_1FtAirFootPlant.xml'
        )
    },
    [ordered]@{
        path = Join-Path $MotionGraphRoot 'BoardAdjusts\T_BoardAdjust_TipGrab.xml'
        virtual_references = @(
            'anim="$GRAB_ANIM_CYC$"',
            'B_SEATBELTGRAB_CYC',
            '2FT_AIR_GRAB_N_TAIL_0_CYC'
        )
    },
    [ordered]@{
        path = Join-Path $MotionGraphRoot 'BoardAdjusts\T_BoardAdjust_NoseGrab.xml'
        virtual_references = @(
            'anim="$GRAB_ANIM_CYC$"',
            'B_CRAILGRAB_CYC',
            '2FT_AIR_GRAB_N_NOSE_0_CYC'
        )
    },
    [ordered]@{
        path = Join-Path $MotionGraphRoot 'BoardAdjusts\T_BA1FtAir.xml'
        virtual_references = @(
            'anim="$INTO_ANIM$"',
            'anim="$CYC_ANIM$"',
            'attName="OneFootAir"'
        )
    },
    [ordered]@{
        path = Join-Path $MotionGraphRoot 'GroundGrabs\Coffin.xml'
        virtual_references = @('B_COFFIN', 'GR_GROUND_N_COFFIN_0_INTO')
    },
    [ordered]@{
        path = $MotionGraphOnBoard
        virtual_references = @(
            'name="UpdateRidingFakie" timeFromTeleportThreshold="1.0"',
            'name="FakieHeadChannel"'
        )
    },
    [ordered]@{
        path = Join-Path $MotionGraphRoot 'switch.xml'
        virtual_references = @(
            'B_SWITCH',
            'time="0.1"',
            'name="WillExpire" InTime="0.02"'
        )
    }
)

foreach ($required in @(
    $Blender,
    $SourceAbin,
    $OffboardAbin,
    $OnboardCatalog,
    $SourceRx2,
    $Exporter,
    $GlbExporter,
    $TargetExporter,
    $FakieWeightVerifier,
    $RetailFakieExporter,
    $MirroredOnboardExporter,
    $CombinedFlipExporter,
    $GlbFootTargetValidator,
    $Glb360FlipPoseValidator,
    $GlbFlipInPoseValidator
) + @(
    if ($PostProcessScript) {
        $PostProcessScript
    }
) + @($graphEvidence | ForEach-Object { $_.path })) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required private source or tool is missing: $required"
    }
}

New-Item -ItemType Directory -Path $PrivateDir -Force | Out-Null
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

& python $FakieWeightVerifier '--abin' $SourceAbin '--importer-dir' $ImporterDir
if ($LASTEXITCODE -ne 0) {
    throw "Retail fakie channel-weight verification failed with exit code $LASTEXITCODE"
}

# The first slice mirrors Skate 3's ground push blend dimensions:
# three-way riding lean, low/high speed, low/high strength, normal/mongo foot,
# directional push variants, start/contact/cycle, and push-out.
$clips = @(
    'R_IDLE_RIDE_N_0_CYC',
    'R_IDLE_HCOM_N100',
    'R_IDLE_HCOM_000',
    'R_IDLE_HCOM_P100',
    'R_IDLE_LCOM_N100',
    'R_IDLE_LCOM_000',
    'R_IDLE_LCOM_P100',
    # Global fakie riding channel plus the neutral style-0 physical B_SWITCH
    # leaf. OnBoard.abin proves 50f @ 30 Hz and 23f @ 30 Hz respectively.
    'FAKIE_CHANNEL_CYC',
    'R_SWITCH_RIDE_N_0_N',

    'R_PUSHLSP_LSTR_N_0_INTO',
    'R_PUSHLSP_LSTR_N_0_CYC1',
    'R_PUSHLSP_LSTR_N_0_CYC2',
    'R_PUSHLSP_HSTR_N_0_INTO',
    'R_PUSHLSP_HSTR_N_0_CYC1',
    'R_PUSHLSP_HSTR_N_0_CYC2',
    'R_PUSHHSP_LSTR_N_0_INTO',
    'R_PUSHHSP_LSTR_N_0_CYC1',
    'R_PUSHHSP_LSTR_N_0_CYC2',
    'R_PUSHHSP_HSTR_N_0_INTO',
    'R_PUSHHSP_HSTR_N_0_CYC1',
    'R_PUSHHSP_HSTR_N_0_CYC2',

    'R_PUSHLSP_LSTR_MONGO_0_INTO',
    'R_PUSHLSP_LSTR_MONGO_0_CYC1',
    'R_PUSHLSP_LSTR_MONGO_0_CYC2',
    'R_PUSHLSP_HSTR_MONGO_0_INTO',
    'R_PUSHLSP_HSTR_MONGO_0_CYC1',
    'R_PUSHLSP_HSTR_MONGO_0_CYC2',
    'R_PUSHHSP_LSTR_MONGO_0_INTO',
    'R_PUSHHSP_LSTR_MONGO_0_CYC1',
    'R_PUSHHSP_LSTR_MONGO_0_CYC2',
    'R_PUSHHSP_HSTR_MONGO_0_INTO',
    'R_PUSHHSP_HSTR_MONGO_0_CYC1',
    'R_PUSHHSP_HSTR_MONGO_0_CYC2',

    'R_PUSHLSP_LSTR_LEFT_0_INTO',
    'R_PUSHLSP_LSTR_LEFT_0_CYC1',
    'R_PUSHLSP_LSTR_LEFT_0_CYC2',
    'R_PUSHLSP_HSTR_LEFT_0_INTO',
    'R_PUSHLSP_HSTR_LEFT_0_CYC1',
    'R_PUSHLSP_HSTR_LEFT_0_CYC2',
    'R_PUSHLSP_LSTR_RIGHT_0_INTO',
    'R_PUSHLSP_LSTR_RIGHT_0_CYC1',
    'R_PUSHLSP_LSTR_RIGHT_0_CYC2',
    'R_PUSHLSP_HSTR_RIGHT_0_INTO',
    'R_PUSHLSP_HSTR_RIGHT_0_CYC1',
    'R_PUSHLSP_HSTR_RIGHT_0_CYC2',
    'R_PUSHHSP_LSTR_LEFT_0_INTO',
    'R_PUSHHSP_LSTR_LEFT_0_CYC1',
    'R_PUSHHSP_LSTR_LEFT_0_CYC2',
    'R_PUSHHSP_HSTR_LEFT_0_INTO',
    'R_PUSHHSP_HSTR_LEFT_0_CYC1',
    'R_PUSHHSP_HSTR_LEFT_0_CYC2',
    'R_PUSHHSP_LSTR_RIGHT_0_INTO',
    'R_PUSHHSP_LSTR_RIGHT_0_CYC1',
    'R_PUSHHSP_LSTR_RIGHT_0_CYC2',
    'R_PUSHHSP_HSTR_RIGHT_0_INTO',
    'R_PUSHHSP_HSTR_RIGHT_0_CYC1',
    'R_PUSHHSP_HSTR_RIGHT_0_CYC2',

    'R_PUSH_L_N_OUT_MIDFRONT',
    'R_PUSH_H_N_OUT_MIDFRONT',
    'R_PUSH_L_M_N_OUT_MIDFRONT',
    'R_PUSH_H_M_N_OUT_MIDFRONT',
    'MONGO_PUSH_TO_ANTIC',
    'MONGO_PUSH_TO_NANTIC',

    # Retail moving foot-brake and stationary stand chains (regular/switch).
    'R_BRAKE_N_N_0_INTO',
    'R_BRAKE_N_N_0_CYC1',
    'R_BRAKE_N_N_0_CYC',
    'R_BRAKE_N_N_0_OUT',
    'R_BRAKE_MONGO_N_0_INTO',
    'R_BRAKE_MONGO_N_0_CYC1',
    'R_BRAKE_MONGO_N_0_CYC',
    'R_BRAKE_MONGO_N_0_OUT',
    'R_STAND_FROMLSBRAKE_N_0_TR',
    'R_STAND_IDLE2_N_0_INTO',
    'R_STAND_IDLE2_N_0_CYC',
    'R_STAND_IDLE2_N_0_OUT',
    'R_STAND_FROMLSBRAKE_MONGO_0_TR',
    'R_STAND_IDLE_MONGO_0_INTO',
    'R_STAND_IDLE_MONGO_0_CYC',
    'R_STAND_IDLE_MONGO_0_OUT',

    # NewRightSlide/NewLeftSlide low/high-speed FS/BS powerslide leaves.
    'R_SLIDE_FS_LSP_INTO',
    'R_SLIDE_FS_LSP_CYC',
    'R_SLIDE_FS_LSP_EARLYOUT',
    'R_SLIDE_FS_LSP_MIDOUT',
    'R_SLIDE_FS_LSP_OUT_000',
    'R_SLIDE_FS_LSP_OUT_090',
    'R_SLIDE_FS_LSP_OUT_180',
    'R_SLIDE_FS_HSP_INTO',
    'R_SLIDE_FS_HSP_CYC',
    'R_SLIDE_FS_HSP_EARLYOUT',
    'R_SLIDE_FS_HSP_MIDOUT',
    'R_SLIDE_FS_HSP_OUT_000',
    'R_SLIDE_FS_HSP_OUT_090',
    'R_SLIDE_FS_HSP_OUT_180',
    'R_SLIDE_BS_LSP_INTO',
    'R_SLIDE_BS_LSP_CYC',
    'R_SLIDE_BS_LSP_EARLYOUT',
    'R_SLIDE_BS_LSP_MIDOUT',
    'R_SLIDE_BS_LSP_OUT_000',
    'R_SLIDE_BS_LSP_OUT_090',
    'R_SLIDE_BS_LSP_OUT_180',
    'R_SLIDE_BS_HSP_INTO',
    'R_SLIDE_BS_HSP_CYC',
    'R_SLIDE_BS_HSP_EARLYOUT',
    'R_SLIDE_BS_HSP_MIDOUT',
    'R_SLIDE_BS_HSP_OUT_000',
    'R_SLIDE_BS_HSP_OUT_090',
    'R_SLIDE_BS_HSP_OUT_180',

    # Default random stationary idles entered after three seconds.
    'R_STAND_STAT_VER1_N_0_CYC',
    'R_STAND_STAT_VER2_N_0_CYC'
)
$baselineOnboardActionCount = $clips.Count

# Wave 2F first trick vertical slice.
#
# The recovered motion graph names below are virtual blend/sequence nodes and
# are deliberately not sent to the ABIN extractor. Their physical OnBoard
# leaves are resolved by the retail naming families and then required to exist
# verbatim in skate3_onboard_clips.csv before Blender is launched.
$trickClips = [System.Collections.Generic.List[string]]::new()

# B_ANTIC_CYC, B_N_ANTIC_CYC, and the four shuv anticipation cycles are
# compression blends with left/neutral/right physical leaves at normal/high
# anticipation strength. The authoritative catalog stores these as indices
# 1..36.
foreach ($family in @(
    'ANTIC_360SHUVIT',
    'ANTIC_FS360SHUVIT',
    'ANTIC_N360SHUVIT',
    'ANTIC_NFS360SHUVIT',
    'ANTIC_NOLLIE',
    'ANTIC_OLLIE',
    'HIGHANTIC_360SHUVIT',
    'HIGHANTIC_FS360SHUVIT',
    'HIGHANTIC_N360SHUVIT',
    'HIGHANTIC_NFS360SHUVIT',
    'HIGHANTIC_NOLLIE',
    'HIGHANTIC_OLLIE'
)) {
    foreach ($lean in @('L', 'N', 'R')) {
        $trickClips.Add("R_${family}_${lean}_0_CYC")
    }
}

# B_ANTIC_INTO/B_N_ANTIC_INTO and B_ANTIC_OUT/B_N_ANTIC_OUT resolve to
# four compression postures for each tail/nose side, again with
# left/neutral/right physical leaves. These are catalog indices 37..84.
foreach ($phase in @('INTO', 'OUT')) {
    foreach ($family in @(
        'ANTIC_CROUCH_HIGHNOLLIE',
        'ANTIC_CROUCH_HIGHOLLIE',
        'ANTIC_CROUCH_NOLLIE',
        'ANTIC_CROUCH_OLLIE',
        'ANTIC_NOLLIE',
        'ANTIC_OLLIE',
        'HIGHANTIC_NOLLIE',
        'HIGHANTIC_OLLIE'
    )) {
        foreach ($lean in @('L', 'N', 'R')) {
            $trickClips.Add("R_${family}_${lean}_0_$phase")
        }
    }
}

# T_Ollie expands B_OLLIE/B_NOLLIE to _G (ground takeoff) followed by _A
# (air), each with low/high TrickHeight leaves.
foreach ($clip in @(
    'OLLIE_LOW_G',
    'OLLIE_LOW_A',
    'OLLIE_HIGH_G',
    'OLLIE_HIGH_A',
    'NOLLIE_LOW_G',
    'NOLLIE_LOW_A',
    'NOLLIE_HIGH_G',
    'NOLLIE_HIGH_A',

    # Exact animation-side companions to the separate airborne PhysBodySpin
    # intent recovered from the retail OnBoard and InAir state graphs.
    'IA_BODYSPIN_OLLIE_BS_0_N',
    'IA_BODYSPIN_OLLIE_FS_0_N',

    # Neutral physical baseline used when the virtual B_AIR_CYC graph returns
    # to ordinary ungrabbed air.
    'IA_IDLE_N_N_0_CYC',

    # Straight BLEND_LAND chooses one of three numbered landings and blends
    # the aggressive/loose posture dimension.
    'L_LAND_HIGH_AGGR_1_N',
    'L_LAND_HIGH_AGGR_2_N',
    'L_LAND_HIGH_AGGR_3_N',
    'L_LAND_HIGH_LOOSE_1_N',
    'L_LAND_HIGH_LOOSE_2_N',
    'L_LAND_HIGH_LOOSE_3_N',

    # BLEND_LAND's recovered high-compression branch blends the numbered
    # HCOM_LIMP support pose with L_LAND_HIGH. Its low-compression sibling is
    # the correspondingly numbered L_LCOM leaf.
    'L_HCOM_LIMP_1',
    'L_HCOM_LIMP_2',
    'L_HCOM_LIMP_3',
    'L_LCOM_1',
    'L_LCOM_2',
    'L_LCOM_3',

    # Exact physical OnBoard ABIN families named behind the virtual Nice and
    # Sketch landing resources. Their provider-side FS/BS, COM, and impact
    # selection policy remains external to the asset exporter.
    'L_NICE_BS_HCOM_HSP_HIMP',
    'L_NICE_BS_HCOM_HSP_LIMP',
    'L_NICE_BS_LCOM_HSP',
    'L_NICE_FS_HCOM_HSP_HIMP',
    'L_NICE_FS_HCOM_HSP_LIMP',
    'L_NICE_FS_LCOM_HSP',
    'L_SKETCH_BS_HCOM_HIMP',
    'L_SKETCH_BS_HCOM_HIMP1',
    'L_SKETCH_BS_HCOM_HIMP2',
    'L_SKETCH_BS_HCOM_HIMP3',
    'L_SKETCH_BS_HCOM_HIMP4',
    'L_SKETCH_BS_HCOM_LIMP',
    'L_SKETCH_BS_HCOM_LIMP1',
    'L_SKETCH_BS_HCOM_LIMP2',
    'L_SKETCH_BS_HCOM_LIMP3',
    'L_SKETCH_BS_HCOM_LIMP4',
    'L_SKETCH_BS_LCOM',
    'L_SKETCH_BS_LCOM1',
    'L_SKETCH_BS_LCOM2',
    'L_SKETCH_BS_LCOM3',
    'L_SKETCH_BS_LCOM4',
    'L_SKETCH_FS_HCOM_HIMP',
    'L_SKETCH_FS_HCOM_HIMP1',
    'L_SKETCH_FS_HCOM_HIMP2',
    'L_SKETCH_FS_HCOM_HIMP3',
    'L_SKETCH_FS_HCOM_HIMP4',
    'L_SKETCH_FS_HCOM_LIMP',
    'L_SKETCH_FS_HCOM_LIMP1',
    'L_SKETCH_FS_HCOM_LIMP2',
    'L_SKETCH_FS_HCOM_LIMP3',
    'L_SKETCH_FS_HCOM_LIMP4',
    'L_SKETCH_FS_LCOM',
    'L_SKETCH_FS_LCOM1',
    'L_SKETCH_FS_LCOM2',
    'L_SKETCH_FS_LCOM3',
    'L_SKETCH_FS_LCOM4'
)) {
    $trickClips.Add($clip)
}

if ($trickClips.Count -ne 143) {
    throw "Wave 2F physical clip resolution changed: expected 143, found $($trickClips.Count)"
}

$catalogRows = @(Import-Csv -LiteralPath $OnboardCatalog)
$catalogByName = @{}
foreach ($row in $catalogRows) {
    if ($catalogByName.ContainsKey($row.name)) {
        throw "Authoritative OnBoard catalog contains duplicate clip name: $($row.name)"
    }
    $catalogByName[$row.name] = $row
}
$missingFromCatalog = @($trickClips | Where-Object { -not $catalogByName.ContainsKey($_) })
if ($missingFromCatalog.Count -gt 0) {
    throw "Wave 2F physical clips are absent from skate3_onboard_clips.csv: $($missingFromCatalog -join ', ')"
}

foreach ($graphSource in $graphEvidence) {
    $graphText = Get-Content -LiteralPath $graphSource.path -Raw
    foreach ($reference in $graphSource.virtual_references) {
        if (-not $graphText.Contains($reference)) {
            throw "Recovered XML evidence changed: '$reference' is absent from $($graphSource.path)"
        }
    }
}

$clips += @($trickClips)

# Evidence-backed non-basic trick leaves.
#
# Kickflip/Heelflip low/high G/A were observed as two-child TrickHeight trees
# in the synchronized read-only Frida captures:
# work/frida-kickflip-charge-sweep.jsonl and
# work/frida-heelflip-layers.jsonl. The D 360 Flip low/high G/A pairs are the
# identity-round-tripped retail leaves pinned by
# 2026-08-02-blender-360flip-roundtrip.json and the Wave 3 air-trick fixture.
# The remaining one-shot families use the exact virtual bases in Tricks.xml
# and the matching low/high G/A OnBoard catalog families. D is the default
# family where named pro alternatives exist (CARR/DILL/GONZ/HSU); this is the
# same default-family selector proven by the 360 Flip round trip.
# GRIND_OUT_NOSE/TAIL are the direct physical resources named by Tricks.xml.
$singleRotationBases = @(
    'POPSHUVIT',
    'FSPOPSHUVIT_D',
    'VARIALKICKFLIP',
    'VARIALHEELFLIP_D',
    'HARDFLIP',
    'INWARDHEELFLIP',
    '360POPSHUVIT',
    'FS360POPSHUVIT',
    '360FLIP_D',
    'LASERFLIP',
    '360HARDFLIP',
    '360INWARDHEELFLIP',
    'N_POPSHUVIT',
    'N_FSPOPSHUVIT',
    'N_VARIALKICKFLIP',
    'N_VARIALHEELFLIP',
    'N_HARDFLIP',
    'N_INWARDHEELFLIP',
    'N_360POPSHUVIT',
    'N_FS360POPSHUVIT',
    'N_360FLIP',
    'N_LASERFLIP',
    'N_360HARDFLIP',
    'N_360INWARDHEELFLIP'
)
$singleRotationClips = @(
    foreach ($base in $singleRotationBases) {
        foreach ($height in @('LOW', 'HIGH')) {
            foreach ($segment in @('G', 'A')) {
                "${base}_${height}_${segment}"
            }
        }
    }
)
$flipLoopClips = @(
    'T_LOW_KICK_CYC1',
    'T_LOW_KICK_CYC2',
    'T_LOW_KICK_CYC3',
    'T_HI_KICK_CYC1',
    'T_HI_KICK_CYC2',
    'T_HI_KICK_CYC3',
    'T_KICKFLIP_LOW_4FLIPS_0_OUT1',
    'T_KICKFLIP_LOW_4FLIPS_0_OUT2',
    'T_KICKFLIP_LOW_4FLIPS_0_OUT3',
    'T_KICKFLIP_HI_4FLIPS_0_OUT1',
    'T_KICKFLIP_HI_4FLIPS_0_OUT2',
    'T_KICKFLIP_HI_4FLIPS_0_OUT3',
    'T_LOW_KICK_OUT4',
    'T_HI_KICK_OUT4',
    'T_LOW_HEEL_CYC1',
    'T_LOW_HEEL_CYC2',
    'T_LOW_HEEL_CYC3',
    'T_HI_HEEL_CYC1',
    'T_HI_HEEL_CYC2',
    'T_HI_HEEL_CYC3',
    'T_HEELFLIP_LOW_4FLIPS_0_OUT1',
    'T_HEELFLIP_LOW_4FLIPS_0_OUT2',
    'T_HEELFLIP_LOW_4FLIPS_0_OUT3',
    'T_HEELFLIP_HI_4FLIPS_0_OUT1',
    'T_HEELFLIP_HI_4FLIPS_0_OUT2',
    'T_HEELFLIP_HI_4FLIPS_0_OUT3',
    'T_LOW_HEEL_OUT4',
    'T_HI_HEEL_OUT4',
    'T_LOW_N_KICK_CYC1',
    'T_LOW_N_KICK_CYC2',
    'T_LOW_N_KICK_CYC3',
    'T_HI_N_KICK_CYC1',
    'T_HI_N_KICK_CYC2',
    'T_HI_N_KICK_CYC3',
    'T_N_KICKFLIP_LOW_4FLIPS_0_OUT1',
    'T_N_KICKFLIP_LOW_4FLIPS_0_OUT2',
    'T_N_KICKFLIP_LOW_4FLIPS_0_OUT3',
    'T_N_KICKFLIP_HI_4FLIPS_0_OUT1',
    'T_N_KICKFLIP_HI_4FLIPS_0_OUT2',
    'T_N_KICKFLIP_HI_4FLIPS_0_OUT3',
    'T_LOW_N_KICK_OUT4',
    'T_HI_N_KICK_OUT4',
    'T_LOW_N_HEEL_CYC1',
    'T_LOW_N_HEEL_CYC2',
    'T_LOW_N_HEEL_CYC3',
    'T_HI_N_HEEL_CYC1',
    'T_HI_N_HEEL_CYC2',
    'T_HI_N_HEEL_CYC3',
    'T_N_HEELFLIP_LOW_4FLIPS_0_OUT1',
    'T_N_HEELFLIP_LOW_4FLIPS_0_OUT2',
    'T_N_HEELFLIP_LOW_4FLIPS_0_OUT3',
    'T_N_HEELFLIP_HI_4FLIPS_0_OUT1',
    'T_N_HEELFLIP_HI_4FLIPS_0_OUT2',
    'T_N_HEELFLIP_HI_4FLIPS_0_OUT3',
    'T_LOW_N_HEEL_OUT4',
    'T_HI_N_HEEL_OUT4'
)
$airTrickClips = @(
    'GRIND_OUT_NOSE',
    'GRIND_OUT_TAIL',
    'KICKFLIP_IN_LOW_G',
    'KICKFLIP_IN_LOW_A',
    'KICKFLIP_IN_HIGH_G',
    'KICKFLIP_IN_HIGH_A',
    'HEELFLIP_IN_LOW_G',
    'HEELFLIP_IN_LOW_A',
    'HEELFLIP_IN_HIGH_G',
    'HEELFLIP_IN_HIGH_A',
    'N_KICKFLIP_IN_LOW_G',
    'N_KICKFLIP_IN_LOW_A',
    'N_KICKFLIP_IN_HIGH_G',
    'N_KICKFLIP_IN_HIGH_A',
    'N_HEELFLIP_IN_LOW_G',
    'N_HEELFLIP_IN_LOW_A',
    'N_HEELFLIP_IN_HIGH_G',
    'N_HEELFLIP_IN_HIGH_A'
) + $singleRotationClips + $flipLoopClips
$missingAirTrickClips = @(
    $airTrickClips |
        Where-Object { -not $catalogByName.ContainsKey($_) }
)
if ($missingAirTrickClips.Count -gt 0) {
    throw "Runtime-verified air-trick clips are absent from skate3_onboard_clips.csv: $($missingAirTrickClips -join ', ')"
}
$clips += @($airTrickClips)

# First held-grab slice. The air into/out/transition leaves are named by the
# recovered graph. Neutral cycles and the neutral members of the ground
# left/neutral/right families are the zero-input physical endpoints.
$basicGrabClips = @(
    'GR_GRAB_N_BS_0_CYC',
    'GR_GRAB_N_BS_0_INTO',
    'GR_GRAB_N_BS_0_OUT',
    'GR_BS2DBL_0_TR',
    'GR_DBL2BS_0_TR',
    'GR_DBL2FS_0_TR',
    'GR_FS2DBL_0_TR',
    'GR_GRAB_N_DBL_0_CYC',
    'GR_GRAB_N_DBL_0_INTO',
    'GR_GRAB_N_DBL_0_OUT',
    'GR_GRAB_N_FS_0_CYC',
    'GR_GRAB_N_FS_0_INTO',
    'GR_GRAB_N_FS_0_OUT',
    'GR_GROUND_N_BS_0_CYC',
    'GR_CROUCH2GRAB_N_BS_0_INTO',
    'GR_GROUND_N_BS_0_OUT',
    'GR_CROUCH2GRAB_N_DBL_0_INTO',
    'GR_GROUND_N_DBL_0_OUT',
    'GR_CROUCH2GRAB_N_FS_0_INTO',
    'GR_GROUND_N_FS_0_OUT',
    'GR_GRAB_N_BS2DBL_0_TR',
    'GR_GRAB_N_DBL2BS_0_TR',
    'GR_GRAB_N_DBL2FS_0_TR',
    'GR_GRAB_N_FS2DBL_0_TR',
    'GR_GROUND_N_DBL_0_CYC',
    'GR_GROUND_N_FS_0_CYC'
)
$missingBasicGrabClips = @(
    $basicGrabClips |
        Where-Object { -not $catalogByName.ContainsKey($_) }
)
if ($missingBasicGrabClips.Count -gt 0) {
    throw "Held-grab clips are absent from skate3_onboard_clips.csv: $($missingBasicGrabClips -join ', ')"
}
$clips += @($basicGrabClips)

# Complete authored grab-family slice. These exact catalog intervals contain
# the retail tweak, directional grab, one-foot/no-foot, Coffin, and Superman
# leaves recovered from the matching ActionGraph/MotionGraph resources. Clips
# already present in the first held-grab slice are excluded deterministically.
$advancedGrabCatalogRanges = @(
    @(477, 512),
    @(551, 623),
    @(645, 680),
    @(694, 699)
)
$advancedGrabClips = @(
    $catalogRows |
        Where-Object {
            $index = [int]$_.index
            ($advancedGrabCatalogRanges | Where-Object {
                $index -ge $_[0] -and $index -le $_[1]
            }).Count -gt 0 -and
            $_.name -notin $basicGrabClips
        } |
        Sort-Object { [int]$_.index } |
        ForEach-Object { $_.name }
)
if ($advancedGrabClips.Count -ne 138) {
    throw "Complete grab catalog selection changed: expected 138 new clips, found $($advancedGrabClips.Count)"
}
$clips += @($advancedGrabClips)

# These generated double-composition actions are negative-control artifacts,
# not runtime resources. Physical ABIN flip leaves already include RIG_TPOSE.
$combinedFlipActions = @(
    'COMBINED_KICKFLIP_LOW_G',
    'COMBINED_KICKFLIP_LOW_A',
    'COMBINED_KICKFLIP_HIGH_G',
    'COMBINED_KICKFLIP_HIGH_A',
    'COMBINED_HEELFLIP_LOW_G',
    'COMBINED_HEELFLIP_LOW_A',
    'COMBINED_HEELFLIP_HIGH_G',
    'COMBINED_HEELFLIP_HIGH_A',
    'COMBINED_N_KICKFLIP_LOW_G',
    'COMBINED_N_KICKFLIP_LOW_A',
    'COMBINED_N_KICKFLIP_HIGH_G',
    'COMBINED_N_KICKFLIP_HIGH_A',
    'COMBINED_N_HEELFLIP_LOW_G',
    'COMBINED_N_HEELFLIP_LOW_A',
    'COMBINED_N_HEELFLIP_HIGH_G',
    'COMBINED_N_HEELFLIP_HIGH_A',
    'COMBINED_360FLIP_LOW_G',
    'COMBINED_360FLIP_LOW_A',
    'COMBINED_360FLIP_HIGH_G',
    'COMBINED_360FLIP_HIGH_A'
)

$offboardClips = @(
    # Flat-ground held-board locomotion leaves selected after a normal
    # user dismount.
    'BR_STAND_0_CYC',
    'BR_WALK_FWD_CYC',
    'BR_RUN_FWD_CYC',
    'BR_SPRINT_FWD_CYC',
    'BR_STAND_0_INTO_WALK_FWD',
    'BR_STAND_0_INTO_RUN_FWD',
    'BR_STAND_0_INTO_SPRINT_FWD',

    # RegDismount blend leaves. The virtual graph blends HI/LO using the
    # disttocog attribute copied from the outgoing riding animation.
    'BR_DISMOUNT_HI_INTO_STAND_0',
    'BR_DISMOUNT_LO_INTO_STAND_0',
    'BR_DISMOUNT_HI_INTO_RUN_FWD',
    'BR_DISMOUNT_LO_INTO_RUN_FWD',
    'BR_DISMOUNT_FAST_HI_INTO_RUN_FWD',
    'BR_DISMOUNT_FAST_LO_INTO_RUN_FWD',

    # MatchCadence resolves the virtual stop and mount animations to these
    # quarter-cycle leaves.
    'BR_WALK_FWD_0_INTO_STAND_0',
    'BR_WALK_FWD_25_INTO_STAND_0',
    'BR_WALK_FWD_50_INTO_STAND_0',
    'BR_WALK_FWD_75_INTO_STAND_0',
    'BR_RUN_FWD_0_INTO_STAND_0',
    'BR_RUN_FWD_25_INTO_STAND_0',
    'BR_RUN_FWD_50_INTO_STAND_0',
    'BR_RUN_FWD_75_INTO_STAND_0',
    'BR_SPRINT_FWD_0_INTO_STAND_0',
    'BR_SPRINT_FWD_25_INTO_STAND_0',
    'BR_SPRINT_FWD_50_INTO_STAND_0',
    'BR_SPRINT_FWD_75_INTO_STAND_0',
    'BR_STAND_0_INTO_MOUNT',
    'BR_STEP_INTO_MOUNT',
    'BR_WALK_FWD_0_INTO_MOUNT',
    'BR_WALK_FWD_25_INTO_MOUNT',
    'BR_WALK_FWD_50_INTO_MOUNT',
    'BR_WALK_FWD_75_INTO_MOUNT',
    'BR_RUN_FWD_0_INTO_MOUNT',
    'BR_RUN_FWD_25_INTO_MOUNT',
    'BR_RUN_FWD_50_INTO_MOUNT',
    'BR_RUN_FWD_75_INTO_MOUNT',
    'BR_SPRINT_FWD_0_INTO_MOUNT',
    'BR_SPRINT_FWD_25_INTO_MOUNT',
    'BR_SPRINT_FWD_50_INTO_MOUNT',
    'BR_SPRINT_FWD_75_INTO_MOUNT'
)

$baselineActionCount = $baselineOnboardActionCount + $offboardClips.Count
if ($baselineActionCount -ne 148) {
    throw "Existing private action baseline changed: expected 148, found $baselineActionCount"
}
$requestedClips = @($clips) + @($offboardClips)
$duplicateRequests = @(
    $requestedClips |
        Group-Object |
        Where-Object { $_.Count -ne 1 } |
        ForEach-Object { $_.Name }
)
if ($duplicateRequests.Count -gt 0) {
    throw "Private action request contains duplicates: $($duplicateRequests -join ', ')"
}
if ($requestedClips.Count -ne 625) {
    throw "Private source action count changed: expected 625, found $($requestedClips.Count)"
}
$fakieBaseActions = @($requestedClips) + @($combinedFlipActions)
$retailFakieActions = @(
    $fakieBaseActions |
        ForEach-Object {
            if ($_ -eq 'R_IDLE_HCOM_000') {
                'RETAIL__B_FAKIE_CHANNEL__R_IDLE_HCOM_000'
            } else {
                "RETAIL__B_FAKIE_CHANNEL__$_"
            }
        }
)
$expectedExportedActions = @($fakieBaseActions)
$expectedExportedActions += $retailFakieActions
$mirroredOnboardActions = @(
    $expectedExportedActions |
        ForEach-Object { "MIRRORED__$_" }
)
$expectedExportedActions += $mirroredOnboardActions
if ($expectedExportedActions.Count -ne 2580) {
    throw "Private exported action count changed: expected 2580, found $($expectedExportedActions.Count)"
}

$arguments = @(
    '--background',
    '--python', $Exporter,
    '--',
    '--abin', $SourceAbin,
    '--extra-abin', $OffboardAbin,
    '--rx2', $SourceRx2,
    '--output', $Blend,
    '--preview-fps', '60'
)
foreach ($clip in $clips) {
    $arguments += @('--clip', $clip)
}
foreach ($clip in $offboardClips) {
    $arguments += @('--extra-clip', $clip)
}

& $Blender @arguments
if (
    $LASTEXITCODE -ne 0 -or
    -not (Test-Path -LiteralPath $Blend) -or
    -not (Test-Path -LiteralPath $Validation)
) {
    throw "RX2/ABIN extraction failed with exit code $LASTEXITCODE"
}

& $Blender '--background' $Blend '--python' $TargetExporter '--' $SourceAbin $ImporterDir
if ($LASTEXITCODE -ne 0) {
    throw "OnBoard SkeletonIK target export failed with exit code $LASTEXITCODE"
}

& $Blender '--background' $Blend '--python' $CombinedFlipExporter '--' $SourceAbin $ImporterDir
if ($LASTEXITCODE -ne 0) {
    throw "Legacy flip-composition diagnostic failed with exit code $LASTEXITCODE"
}

if ($PostProcessScript) {
    & $Blender '--background' $Blend '--python' $PostProcessScript '--' @PostProcessArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Private mesh/material post-process failed with exit code $LASTEXITCODE"
    }
}

& $Blender '--background' $Blend '--python-exit-code' '1' '--python' $RetailFakieExporter
if ($LASTEXITCODE -ne 0) {
    throw "Retail fakie channel action-bank composition failed with exit code $LASTEXITCODE"
}

& $Blender '--background' $Blend '--python-exit-code' '1' '--python' $MirroredOnboardExporter
if ($LASTEXITCODE -ne 0) {
    throw "Retail mirrored onboard action export failed with exit code $LASTEXITCODE"
}

& $Blender '--background' $Blend '--python' $GlbExporter '--' $Glb $Manifest $RootMotion
if (
    $LASTEXITCODE -ne 0 -or
    -not (Test-Path -LiteralPath $Glb) -or
    -not (Test-Path -LiteralPath $Manifest) -or
    -not (Test-Path -LiteralPath $RootMotion)
) {
    throw "Bevy glTF export failed with exit code $LASTEXITCODE"
}

& $Blender '--background' '--python' $GlbFootTargetValidator '--' `
    $Glb 'COMBINED_' '0.05'
if ($LASTEXITCODE -ne 0) {
    throw "Exported combined foot-target validation failed with exit code $LASTEXITCODE"
}
& $Blender '--background' '--python' $GlbFootTargetValidator '--' `
    $Glb '360FLIP_D_' '0.05'
if ($LASTEXITCODE -ne 0) {
    throw "Exported physical 360 Flip target validation failed with exit code $LASTEXITCODE"
}
& $Blender '--background' '--python' $GlbFootTargetValidator '--' `
    $Glb 'KICKFLIP_IN_,HEELFLIP_IN_,N_KICKFLIP_IN_,N_HEELFLIP_IN_' '0.05'
if ($LASTEXITCODE -ne 0) {
    throw "Exported physical flip-IN target validation failed with exit code $LASTEXITCODE"
}
& $Blender '--background' '--python' $GlbFootTargetValidator '--' `
    $Glb `
    'T_LOW_KICK_,T_HI_KICK_,T_KICKFLIP_LOW_4FLIPS_0_OUT,T_KICKFLIP_HI_4FLIPS_0_OUT,T_LOW_HEEL_,T_HI_HEEL_,T_HEELFLIP_LOW_4FLIPS_0_OUT,T_HEELFLIP_HI_4FLIPS_0_OUT,T_LOW_N_KICK_,T_HI_N_KICK_,T_N_KICKFLIP_LOW_4FLIPS_0_OUT,T_N_KICKFLIP_HI_4FLIPS_0_OUT,T_LOW_N_HEEL_,T_HI_N_HEEL_,T_N_HEELFLIP_LOW_4FLIPS_0_OUT,T_N_HEELFLIP_HI_4FLIPS_0_OUT' `
    '0.05'
if ($LASTEXITCODE -ne 0) {
    throw "Exported flip-loop target validation failed with exit code $LASTEXITCODE"
}
& $Blender '--background' '--python' $Glb360FlipPoseValidator '--' $Glb
if ($LASTEXITCODE -ne 0) {
    throw "Exported physical 360 Flip pose validation failed with exit code $LASTEXITCODE"
}
& $Blender '--background' '--python' $GlbFlipInPoseValidator '--' $Glb
if ($LASTEXITCODE -ne 0) {
    throw "Exported physical flip-IN pose validation failed with exit code $LASTEXITCODE"
}

function Assert-ExactActionSet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,
        [Parameter(Mandatory = $true)]
        [object[]]$Actual,
        [Parameter(Mandatory = $true)]
        [object[]]$Expected
    )

    $actualNames = @($Actual | ForEach-Object { [string]$_ })
    $expectedNames = @($Expected | ForEach-Object { [string]$_ })
    $duplicates = @(
        $actualNames |
            Group-Object |
            Where-Object { $_.Count -ne 1 } |
            ForEach-Object { $_.Name }
    )
    $missing = @($expectedNames | Where-Object { $_ -notin $actualNames })
    $extra = @($actualNames | Where-Object { $_ -notin $expectedNames })
    if (
        $duplicates.Count -gt 0 -or
        $missing.Count -gt 0 -or
        $extra.Count -gt 0 -or
        $actualNames.Count -ne $expectedNames.Count
    ) {
        throw (
            "$Label action-set mismatch. " +
            "expected=$($expectedNames.Count) actual=$($actualNames.Count) " +
            "duplicates=[$($duplicates -join ', ')] " +
            "missing=[$($missing -join ', ')] extra=[$($extra -join ', ')]"
        )
    }
}

function Get-GlbAnimationNames {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $stream = [System.IO.File]::OpenRead($Path)
    $reader = [System.IO.BinaryReader]::new($stream)
    try {
        $magic = $reader.ReadUInt32()
        $version = $reader.ReadUInt32()
        $declaredLength = $reader.ReadUInt32()
        if ($magic -ne 0x46546C67 -or $version -ne 2) {
            throw "Not a glTF 2 GLB: $Path"
        }
        if ($declaredLength -ne $stream.Length) {
            throw "GLB declared length $declaredLength does not match file length $($stream.Length): $Path"
        }

        $jsonLength = $reader.ReadUInt32()
        $jsonType = $reader.ReadUInt32()
        if ($jsonType -ne 0x4E4F534A) {
            throw "GLB first chunk is not JSON: $Path"
        }
        $jsonBytes = $reader.ReadBytes($jsonLength)
        if ($jsonBytes.Length -ne $jsonLength) {
            throw "GLB JSON chunk is truncated: $Path"
        }
        $jsonText = [System.Text.Encoding]::UTF8.GetString($jsonBytes).TrimEnd(
            [char[]]@(0, 9, 10, 13, 32)
        )
        $gltf = $jsonText | ConvertFrom-Json
        return @($gltf.animations | ForEach-Object { $_.name })
    }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

$validationJson = Get-Content -LiteralPath $Validation -Raw | ConvertFrom-Json
$validationActions = @($validationJson.clips | ForEach-Object { $_.name })
Assert-ExactActionSet -Label 'RX2/ABIN validation JSON' -Actual $validationActions -Expected $requestedClips

$manifestLines = @(Get-Content -LiteralPath $Manifest)
$manifestActions = @(
    $manifestLines |
        Where-Object { $_.StartsWith('action=') } |
        ForEach-Object { $_.Substring('action='.Length) }
)
Assert-ExactActionSet -Label 'Private manifest' -Actual $manifestActions -Expected $expectedExportedActions
if ("actions=$($expectedExportedActions.Count)" -notin $manifestLines) {
    throw "Private manifest action count is not $($expectedExportedActions.Count)"
}

$rootMotionJson = Get-Content -LiteralPath $RootMotion -Raw | ConvertFrom-Json
$rootMotionActions = @($rootMotionJson.actions.PSObject.Properties.Name)
Assert-ExactActionSet -Label 'Root-motion JSON' -Actual $rootMotionActions -Expected $expectedExportedActions

$glbActions = @(Get-GlbAnimationNames -Path $Glb)
Assert-ExactActionSet -Label 'GLB animation table' -Actual $glbActions -Expected $expectedExportedActions

$glbHash = Get-Sha256Hash -LiteralPath $Glb
$abinHash = Get-Sha256Hash -LiteralPath $SourceAbin
$offboardHash = Get-Sha256Hash -LiteralPath $OffboardAbin
$catalogHash = Get-Sha256Hash -LiteralPath $OnboardCatalog
$rootMotionHash = Get-Sha256Hash -LiteralPath $RootMotion
$validationHash = Get-Sha256Hash -LiteralPath $Validation
Add-Content -LiteralPath $Manifest -Value "onboard_source=$SourceAbin"
Add-Content -LiteralPath $Manifest -Value "onboard_sha256=$($abinHash.Hash)"
Add-Content -LiteralPath $Manifest -Value "offboard_source=$OffboardAbin"
Add-Content -LiteralPath $Manifest -Value "offboard_sha256=$($offboardHash.Hash)"
Add-Content -LiteralPath $Manifest -Value "onboard_catalog_source=$OnboardCatalog"
Add-Content -LiteralPath $Manifest -Value "onboard_catalog_sha256=$($catalogHash.Hash)"
foreach ($graphSource in $graphEvidence) {
    $graphHash = Get-Sha256Hash -LiteralPath $graphSource.path
    Add-Content -LiteralPath $Manifest -Value "motion_graph_source=$($graphSource.path)"
    Add-Content -LiteralPath $Manifest -Value "motion_graph_sha256=$($graphHash.Hash)"
}
Add-Content -LiteralPath $Manifest -Value "baseline_actions=$baselineActionCount"
Add-Content -LiteralPath $Manifest -Value "wave_2f_actions=$($trickClips.Count)"
Add-Content -LiteralPath $Manifest -Value "wave_3_runtime_verified_air_trick_actions=$($airTrickClips.Count)"
Add-Content -LiteralPath $Manifest -Value "wave_held_grab_actions=$($basicGrabClips.Count)"
Add-Content -LiteralPath $Manifest -Value "wave_complete_grab_actions=$($advancedGrabClips.Count)"
Add-Content -LiteralPath $Manifest -Value "root_motion_sha256=$($rootMotionHash.Hash)"
Add-Content -LiteralPath $Manifest -Value "validation_sha256=$($validationHash.Hash)"
Add-Content -LiteralPath $Manifest -Value "glb_sha256=$($glbHash.Hash)"

$resolvedClipEvidence = @(
    @($trickClips) + @($basicGrabClips) + @($advancedGrabClips) |
        ForEach-Object {
            $row = $catalogByName[$_]
            [ordered]@{
                name = $row.name
                catalog_index = [int]$row.index
                codec = $row.codec
                native_fps = [double]$row.fps
                frames = [int]$row.frames
                block_offset = [int64]$row.block_offset
                block_size = [int64]$row.block_size
            }
        }
)
$graphEvidenceOutput = @(
    $graphEvidence |
        ForEach-Object {
            $hash = Get-Sha256Hash -LiteralPath $_.path
            [ordered]@{
                path = $_.path
                sha256 = $hash.Hash
                observed_virtual_references = $_.virtual_references
            }
        }
)
[ordered]@{
    schema_version = 1
    finding = 'Wave 2F first evidence-backed trick vertical slice'
    interpretation = 'Recovered XML virtual animation nodes resolved to physical OnBoard ABIN clips; virtual names were not requested from the extractor.'
    confidence = 'high'
    baseline_actions_preserved = $baselineActionCount
    wave_2f_physical_actions_added = $trickClips.Count
    wave_3_runtime_verified_air_trick_actions_added = $airTrickClips.Count
    held_grab_physical_actions_added = $basicGrabClips.Count
    complete_grab_physical_actions_added = $advancedGrabClips.Count
    generated_combined_flip_actions = $combinedFlipActions.Count
    generated_retail_fakie_actions = $retailFakieActions.Count
    generated_mirrored_onboard_actions = $mirroredOnboardActions.Count
    total_actions_verified = $expectedExportedActions.Count
    source = [ordered]@{
        onboard_abin = $SourceAbin
        onboard_sha256 = $abinHash.Hash
        offboard_abin = $OffboardAbin
        offboard_sha256 = $offboardHash.Hash
        onboard_catalog = $OnboardCatalog
        onboard_catalog_sha256 = $catalogHash.Hash
        recovered_xml = $graphEvidenceOutput
    }
    resolved_physical_clips = $resolvedClipEvidence
    verification = [ordered]@{
        validation_json = $Validation
        validation_sha256 = $validationHash.Hash
        validation_actions = $validationActions.Count
        manifest = $Manifest
        manifest_actions = $manifestActions.Count
        root_motion_json = $RootMotion
        root_motion_sha256 = $rootMotionHash.Hash
        root_motion_actions = $rootMotionActions.Count
        glb = $Glb
        glb_sha256 = $glbHash.Hash
        glb_actions = $glbActions.Count
    }
} |
    ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath $Evidence -Encoding utf8

Write-Output "Private Bevy asset ready: $Glb"
Write-Output "Validation: $Validation"
Write-Output "Evidence: $Evidence"
Write-Output "Actions: baseline=$baselineActionCount wave_2f=$($trickClips.Count) wave_3_air=$($airTrickClips.Count) held_grab=$($basicGrabClips.Count) complete_grab=$($advancedGrabClips.Count) combined_flip=$($combinedFlipActions.Count) retail_fakie=$($retailFakieActions.Count) mirrored_onboard=$($mirroredOnboardActions.Count) total=$($expectedExportedActions.Count)"
Write-Output "SHA256: $($glbHash.Hash)"
