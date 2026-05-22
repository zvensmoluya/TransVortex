# Subtitle Delivery Sample

This sample exercises the presentation layer only. It uses structured `Segment`
data directly and does not run ASR, translation, prompt repair, or memory logic.

```powershell
python -m transvortex.cli --root . export --segments samples\subtitle_delivery\segments.delivery_sample.json --format both --output samples\subtitle_delivery\preview --bilingual --json
python -m transvortex.cli --root . export --segments samples\subtitle_delivery\segments.delivery_sample.json --format vtt --output samples\subtitle_delivery\preview --bilingual --json
```

The sample covers short text, long bilingual text, CJK plus English and numeric
mixing, and cues that should be checked over bright, dark, and busy footage.
