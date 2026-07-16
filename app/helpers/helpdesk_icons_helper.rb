# Icon-Kompatibilitaet ueber Redmine-Versionen hinweg.
# Redmine 6 rendert Icons per SVG-Sprite (`sprite_icon`); die alten
# `icon icon-*`-CSS-Klassen wurden in Redmine 7 entfernt. Dieser Helfer nutzt
# `sprite_icon`, wenn verfuegbar (Redmine 6/7), und faellt sonst auf das reine
# Label zurueck (Redmine 5, wo die `icon icon-*`-Klasse am Link das Icon liefert).
module HelpdeskIconsHelper
  def hd_icon_label(icon, label = nil)
    if respond_to?(:sprite_icon)
      sprite_icon(icon.to_s, label)
    else
      label.to_s.html_safe
    end
  end
end
