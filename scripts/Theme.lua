-- ============================================================================
-- Theme.lua - Astroon v1.1.0 Design Token
-- 来源: TapMakerDS Astroon 主题包 (Pencil .pen)
-- ============================================================================

local Theme = {}

-- ============================================================================
-- 色彩 Token（十六进制 → RGBA 分量 0-255）
-- ============================================================================

-- 核心色
Theme.primary       = { 255, 213, 79 }       -- #FFD54F  金黄
Theme.primaryHover  = { 255, 224, 102 }       -- #FFE066
Theme.primaryPress  = { 240, 160, 48 }        -- #F0A030
Theme.secondary     = { 74, 139, 245 }        -- #4A8BF5  蓝
Theme.secondaryHov  = { 91, 156, 246 }        -- #5B9CF6
Theme.secondaryPrs  = { 51, 102, 204 }        -- #3366CC
Theme.accent        = { 61, 214, 232 }        -- #3DD6E8  青

-- 背景/表面
Theme.bg            = { 26, 17, 64 }          -- #1A1140  深紫
Theme.bgMid         = { 45, 27, 105 }         -- #2D1B69  中紫
Theme.surface       = { 42, 31, 94 }          -- #2A1F5E
Theme.surfaceHover  = { 61, 42, 138 }         -- #3D2A8A
Theme.overlay       = { 0, 0, 0 }             -- #000000B4  (alpha 180)
Theme.overlayAlpha  = 180

-- 文字
Theme.text          = { 255, 255, 255 }       -- #FFFFFF
Theme.textSec       = { 255, 255, 255 }       -- #FFFFFFAA (alpha 170)
Theme.textSecAlpha  = 170
Theme.textMuted     = { 255, 255, 255 }       -- #FFFFFF55 (alpha 85)
Theme.textMutedAlpha = 85
Theme.textDisabled  = { 255, 255, 255 }       -- #FFFFFF40 (alpha 64)
Theme.textDisabledA = 64

-- 边框
Theme.border        = { 255, 255, 255 }       -- #FFFFFF18 (alpha 24)
Theme.borderAlpha   = 24
Theme.borderFocus   = { 74, 139, 245 }        -- #4A8BF5

-- 语义色
Theme.success       = { 46, 204, 113 }        -- #2ECC71
Theme.successHover  = { 61, 216, 138 }        -- #3DD88A
Theme.error         = { 255, 71, 87 }         -- #FF4757
Theme.errorHover    = { 255, 107, 122 }       -- #FF6B7A
Theme.warning       = { 255, 217, 61 }        -- #FFD93D
Theme.warningHover  = { 255, 224, 102 }       -- #FFE066
Theme.info          = { 61, 214, 232 }        -- #3DD6E8

-- HUD 专用
Theme.hudHP         = { 255, 71, 87 }         -- #FF4757
Theme.hudMP         = { 74, 139, 245 }        -- #4A8BF5
Theme.hudStamina    = { 255, 217, 61 }        -- #FFD93D
Theme.hudXP         = { 46, 204, 113 }        -- #2ECC71

-- 禁用
Theme.disabled      = { 61, 42, 138 }         -- #3D2A8A
Theme.disabledText  = { 255, 255, 255 }       -- #FFFFFF55

-- 高光
Theme.highlight     = { 255, 255, 255 }       -- #FFFFFF30 (alpha 48)
Theme.highlightA    = 48
Theme.shadow        = { 0, 0, 0 }             -- #00000060 (alpha 96)
Theme.shadowAlpha   = 96

-- ============================================================================
-- 圆角 Token
-- ============================================================================

Theme.radiusSm  = 6
Theme.radiusMd  = 10
Theme.radiusLg  = 16
Theme.radiusXl  = 20
Theme.radiusPill = 9999

-- ============================================================================
-- 间距 Token
-- ============================================================================

Theme.spXs  = 4
Theme.spSm  = 8
Theme.spMd  = 12
Theme.spLg  = 16
Theme.spXl  = 24
Theme.spXxl = 32

-- ============================================================================
-- 字体
-- ============================================================================

Theme.fontFamily     = "Inter"
Theme.fontH1         = 28
Theme.fontH2         = 22
Theme.fontH3         = 18
Theme.fontBody       = 14
Theme.fontBodySmall  = 12
Theme.fontCaption    = 10

-- ============================================================================
-- 便利函数
-- ============================================================================

--- 返回 nvgRGBA 参数（展开为 r, g, b, a）
function Theme.rgba(token, alpha)
    return token[1], token[2], token[3], alpha or 255
end

return Theme
