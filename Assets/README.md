# MZT Player icon

The app icon is a red enamel interpretation of the Sharp MZ ship emblem on a charcoal macOS tile. Generated with the built-in image-generation tool; the final PNG retains alpha outside the tile.

Master: `MZTPlayerIcon.png`. `build-icon.sh` creates the ten standard PNG representations and packages them as `AppIcon.icns` for the app bundle. The main window also uses this icon. The app build copies the prepared `AppIcon.icns`; to regenerate it after artwork changes, run `./Assets/build-icon.sh "$PWD/Assets/AppIcon.icns"` from the project directory. macOS icon packaging may require execution outside a restricted sandbox.

Reference: [Sharp’s official article on its logo history](https://note.com/sharp/n/n5442de10d262), published 5 September 2025. Sharp identifies the emblem as the Argo. The emblem belongs to Sharp; the artwork is an adaptation for MZT Player.

## Generation prompt

Use case: stylized-concept
Asset type: single polished macOS app icon for MZT Player, square 1024 by 1024.
Reference image role: the photograph is a shape reference ONLY. The small red ship emblem printed on the right of the Sharp MZ-80K is the subject to faithfully reproduce, not the computer or keyboard. It is the Sharp MZ Argo ship, often called the Viking ship. Preserve its distinctive graphic silhouette, slender triangular mast rigging, curled ornate upward bow on the RIGHT, row of circular oar ports and FOUR diagonal oars. Study and reproduce this specific emblem rather than inventing a generic Viking longship, square sail or dragon.
Primary request: Centre a large, beautifully crisp rendition of that exact red ship emblem on a warm ivory rounded-square macOS icon tile. Refined sculpted enamel finish, subtle shallow relief, precise cut-out negative spaces, soft studio lighting, restrained bevel, faint contact shadow, clean luxury industrial design with a 1980s Sharp computing character. Bold vermilion red emblem and warm off-white tile, no other colours, no added typography or symbols. The ship occupies about 68 percent of the tile width and 65 percent of the tile height, balanced optical centring. Tile occupies about 88 percent of the square canvas and has consistent macOS rounded corners. Transparent canvas outside the tile, genuine alpha.
Constraints: faithful historic Sharp MZ ship silhouette, orthographic front view, legible at 32 pixels. No cassette, no keyboard, no computer, no words, no lettering, no waveforms, no play badge, no surrounding UI, no mockup, no multi-icon grid. Deliver a finished icon asset only.

## Edge refinement prompt

Edit this application icon. Preserve the red Sharp MZ Argo ship emblem, its geometry, four oars, materials, ivory tile, composition and lighting exactly. Correct ONLY the outside perimeter and transparency: remove every stray white speck, fringe, fleck, detached pixel and irregular patch around the tile. Give the ivory rounded-square tile an impeccably smooth continuous antialiased silhouette, with all canvas outside that silhouette fully transparent. No particles or decorative edge texture. Keep the tile centred on a perfectly square canvas with consistent empty margins. Production macOS icon asset, clean alpha channel. Do not alter the ship or add anything.

## Final colour and edge refinement prompt

Make one targeted design change to this macOS application icon: change the IVORY TILE to a perfectly smooth deep charcoal graphite tile, near-black #202328, with a restrained satin bevel. Keep the Sharp MZ red Argo ship emblem, its precise silhouette, four oars, mast and ornate bow exactly unchanged. Centre and size identically. Remove ALL light speckles, flecks and detached fragments outside the tile. Its outer contour must be a pristine continuous rounded square with smooth antialiasing, with completely transparent empty canvas beyond it. No white halo. No added text, badges, marks or objects. The dark tile and red enamel emblem must read boldly at small Dock sizes. Single square production icon asset.
