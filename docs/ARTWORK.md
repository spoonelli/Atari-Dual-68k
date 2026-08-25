# Platform artwork

**The marquee art is under the same rule as ROM data: use it locally, never
distribute it.** This repository ships an original text placeholder and nothing
else. No release zip, tag, or branch may contain the real marquee.

That rule is now enforced in three places rather than trusted:

| where | what it does |
|---|---|
| `support/package.sh` guard 5 | refuses to build a zip unless `Platforms/_images/eprom.bin` hashes to the placeholder, and names the marquee explicitly if that is what it finds |
| `support/test_package_guards.sh` | provokes guard 5 with the real artwork, so the guard is known to fire |
| git history | the art was purged (it was added in `141ef2e`, since rewritten out) |

Guards 3 and 4 do **not** cover this. The image is under the size limit and
sits at an expected manifest path, so before guard 5 a copied-in marquee would
have packaged silently — the same shape of hole that let a ROM ship as
`gfxdata.bin` when only guard 1 existed.

## Using the real artwork on your own device

The art lives outside the repository, exactly like the romset:

```
/Users/lloyd/Documents/Lloyd Projects/artwork/eprom.bin
```

It is a **165 x 521** image, 2 bytes per pixel, 171,930 bytes — note the
orientation: it is stored rotated, so a 521x165 decode produces noise rather
than a picture. That cost an hour once; it is written down here so it does not
cost another.

Install it **on the SD card, after the core is installed** — never into the
working tree, where it could be committed or packaged:

```bash
./support/install_artwork.sh /Volumes/POCKET
```

The script refuses to write anywhere inside the repository, and verifies the
bytes it copied. To go back to the shipping placeholder, reinstall the core zip.

## If you are changing the placeholder

Update `PLACEHOLDER_SHA256` in `support/package.sh` in the same commit as the
new image. That edit is deliberately required: it is the moment someone has to
decide, in writing, that what they are about to ship is distributable.
