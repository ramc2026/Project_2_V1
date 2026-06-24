param(
    [string]$SpritesRoot = "images/sprites",
    [int]$BackgroundDistanceThreshold = 42,
    [int]$ColorSpreadThreshold = 18,
    [int]$MinComponentArea = 700,
    [int]$Padding = 8,
    [int]$PruneMinNeighbors = 3,
    [int]$PrunePasses = 2,
    [int]$ForceBackgroundR = -1,
    [int]$ForceBackgroundG = -1,
    [int]$ForceBackgroundB = -1,
    [string]$ForceSplitCharacter = "",
    [int]$ForceSplitSequence = -1,
    [int]$ForceSplitColumns = 0,
    [switch]$ForceSplitUseRowBounds,
    [string]$DisableBorderCleanupCharacter = "",
    [int]$DisableBorderCleanupSequence = -1,
    [string[]]$Characters,
    [switch]$CleanOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing

if (-not ("SpriteSheetExtractorV7" -as [type])) {
Add-Type -ReferencedAssemblies @("System.Drawing") -TypeDefinition @"
using System;
using System.IO;
using System.Drawing;
using System.Collections.Generic;
using System.Linq;

public sealed class SpriteComponentV7 {
    public int X;
    public int Y;
    public int Width;
    public int Height;
    public int Area;
    public double Fill;
    public double CenterX;
    public double CenterY;
}

public sealed class SpriteExtractResultV7 {
    public int BackgroundR;
    public int BackgroundG;
    public int BackgroundB;
    public SpriteComponentV7[] Components;
}

public static class SpriteSheetExtractorV7 {
    public static SpriteExtractResultV7 Analyze(string imagePath, int distanceThreshold, int spreadThreshold, int minArea, int borderStep, int pruneMinNeighbors, int prunePasses, int forceBgR, int forceBgG, int forceBgB) {
        using (Bitmap bmp = new Bitmap(imagePath)) {
            int w = bmp.Width;
            int h = bmp.Height;
            Color bg = (forceBgR >= 0 && forceBgG >= 0 && forceBgB >= 0)
                ? Color.FromArgb(forceBgR, forceBgG, forceBgB)
                : GetBorderMedianColor(bmp, Math.Max(1, borderStep));
            bool[] mask = BuildForegroundMask(bmp, bg, distanceThreshold, spreadThreshold, pruneMinNeighbors, prunePasses);
            SpriteComponentV7[] components = FindComponents(mask, w, h, minArea);

            return new SpriteExtractResultV7 {
                BackgroundR = bg.R,
                BackgroundG = bg.G,
                BackgroundB = bg.B,
                Components = components
            };
        }
    }

    public static void SaveFrame(string imagePath, string outputPath, int x, int y, int width, int height, int padding, int bgR, int bgG, int bgB, int distanceThreshold, int spreadThreshold, bool disableBorderCleanup) {
        using (Bitmap source = new Bitmap(imagePath)) {
            int x0 = Math.Max(0, x - padding);
            int y0 = Math.Max(0, y - padding);
            int x1 = Math.Min(source.Width - 1, x + width - 1 + padding);
            int y1 = Math.Min(source.Height - 1, y + height - 1 + padding);

            int outW = x1 - x0 + 1;
            int outH = y1 - y0 + 1;

            using (Bitmap frame = new Bitmap(outW, outH, System.Drawing.Imaging.PixelFormat.Format32bppArgb)) {
                int thresholdSquared = distanceThreshold * distanceThreshold;
                bool[] rawMask = new bool[outW * outH];

                for (int oy = 0; oy < outH; oy++) {
                    int sy = y0 + oy;
                    for (int ox = 0; ox < outW; ox++) {
                        int sx = x0 + ox;
                        Color p = source.GetPixel(sx, sy);
                        if (IsForeground(p, bgR, bgG, bgB, thresholdSquared, spreadThreshold)) {
                            rawMask[oy * outW + ox] = true;
                        }
                    }
                }

                bool[] cleanedMask = disableBorderCleanup ? rawMask : RemoveBorderConnectedForeground(rawMask, outW, outH);
                int cleanedCount = 0;
                for (int i = 0; i < cleanedMask.Length; i++) {
                    if (cleanedMask[i]) {
                        cleanedCount++;
                    }
                }

                // Fallback to raw mask if cleanup removes almost everything.
                bool[] finalMask = cleanedCount >= 24 ? cleanedMask : rawMask;
                bool[] lineTrimmedMask = RemoveFrameGuideLines(finalMask, outW, outH);
                int trimmedCount = 0;
                for (int i = 0; i < lineTrimmedMask.Length; i++) {
                    if (lineTrimmedMask[i]) {
                        trimmedCount++;
                    }
                }

                // Keep pre-trim mask if line trimming got too aggressive.
                if (trimmedCount >= 24) {
                    finalMask = lineTrimmedMask;
                }

                bool[] isolatedMask = KeepDominantSubjectComponent(finalMask, outW, outH);
                int isolatedCount = 0;
                for (int i = 0; i < isolatedMask.Length; i++) {
                    if (isolatedMask[i]) {
                        isolatedCount++;
                    }
                }

                if (isolatedCount >= 24) {
                    finalMask = isolatedMask;
                }

                bool[] tinyPrunedMask = RemoveTinyMaskComponents(finalMask, outW, outH, 14);
                int tinyPrunedCount = 0;
                for (int i = 0; i < tinyPrunedMask.Length; i++) {
                    if (tinyPrunedMask[i]) {
                        tinyPrunedCount++;
                    }
                }

                if (tinyPrunedCount >= 24) {
                    finalMask = tinyPrunedMask;
                }

                bool[] strokePrunedMask = PruneThinMaskStrokes(finalMask, outW, outH, 3, 1);
                int strokePrunedCount = 0;
                for (int i = 0; i < strokePrunedMask.Length; i++) {
                    if (strokePrunedMask[i]) {
                        strokePrunedCount++;
                    }
                }

                if (strokePrunedCount >= 24) {
                    finalMask = strokePrunedMask;
                }

                for (int oy = 0; oy < outH; oy++) {
                    int sy = y0 + oy;
                    for (int ox = 0; ox < outW; ox++) {
                        int sx = x0 + ox;
                        Color p = source.GetPixel(sx, sy);
                        bool keep = finalMask[oy * outW + ox];

                        if (keep) {
                            frame.SetPixel(ox, oy, Color.FromArgb(255, p.R, p.G, p.B));
                        }
                        else {
                            frame.SetPixel(ox, oy, Color.FromArgb(0, 0, 0, 0));
                        }
                    }
                }

                frame.Save(outputPath, System.Drawing.Imaging.ImageFormat.Png);
            }
        }
    }

    private sealed class LocalMaskComponent {
        public List<int> Pixels = new List<int>();
        public int Area;
        public bool TouchLeft;
        public bool TouchRight;
        public bool TouchTop;
        public bool TouchBottom;
    }

    private static bool[] RemoveBorderConnectedForeground(bool[] source, int width, int height) {
        bool[] visited = new bool[source.Length];
        List<LocalMaskComponent> components = new List<LocalMaskComponent>();
        int[] queue = new int[source.Length];

        for (int i = 0; i < source.Length; i++) {
            if (!source[i] || visited[i]) {
                continue;
            }

            LocalMaskComponent comp = new LocalMaskComponent();
            int head = 0;
            int tail = 0;
            queue[tail++] = i;
            visited[i] = true;

            while (head < tail) {
                int idx = queue[head++];
                int x = idx % width;
                int y = idx / width;

                comp.Pixels.Add(idx);
                comp.Area++;
                if (x == 0) comp.TouchLeft = true;
                if (x == width - 1) comp.TouchRight = true;
                if (y == 0) comp.TouchTop = true;
                if (y == height - 1) comp.TouchBottom = true;

                for (int dy = -1; dy <= 1; dy++) {
                    for (int dx = -1; dx <= 1; dx++) {
                        if (dx == 0 && dy == 0) {
                            continue;
                        }

                        int nx = x + dx;
                        int ny = y + dy;
                        if (nx < 0 || ny < 0 || nx >= width || ny >= height) {
                            continue;
                        }

                        int ni = ny * width + nx;
                        if (!source[ni] || visited[ni]) {
                            continue;
                        }

                        visited[ni] = true;
                        queue[tail++] = ni;
                    }
                }
            }

            components.Add(comp);
        }

        if (components.Count == 0) {
            return source;
        }

        int totalArea = components.Sum(c => c.Area);
        int interiorArea = components.Where(c => !(c.TouchLeft || c.TouchRight || c.TouchTop || c.TouchBottom)).Sum(c => c.Area);
        int dominantArea = components.Count > 0 ? components.Max(c => c.Area) : 0;

        bool[] result = new bool[source.Length];
        foreach (LocalMaskComponent comp in components) {
            bool touchesBorder = comp.TouchLeft || comp.TouchRight || comp.TouchTop || comp.TouchBottom;
            int borderTouchCount = (comp.TouchLeft ? 1 : 0) + (comp.TouchRight ? 1 : 0) + (comp.TouchTop ? 1 : 0) + (comp.TouchBottom ? 1 : 0);

            bool keep = true;
            if (touchesBorder) {
                bool dominatesMask = comp.Area >= Math.Max(700, (int)Math.Round(totalArea * 0.45));
                bool hasOnlyBorderComponents = interiorArea == 0;
                bool tinyBorderNoise = comp.Area < Math.Max(120, (int)Math.Round(totalArea * 0.22));
                bool broadBorderBand = borderTouchCount >= 2 && comp.Area < Math.Max(1200, (int)Math.Round(totalArea * 0.55));

                if (hasOnlyBorderComponents) {
                    // When everything touches frame edges, keep only dominant pieces.
                    int dominantThreshold = Math.Max(220, (int)Math.Round(dominantArea * 0.55));
                    if (comp.Area < dominantThreshold) {
                        keep = false;
                    }
                }
                else if (!dominatesMask && (tinyBorderNoise || broadBorderBand)) {
                    keep = false;
                }
            }

            if (!keep) {
                continue;
            }

            foreach (int p in comp.Pixels) {
                result[p] = true;
            }
        }

        return result;
    }

    private static bool[] RemoveFrameGuideLines(bool[] source, int width, int height) {
        bool[] result = new bool[source.Length];
        Array.Copy(source, result, source.Length);

        int[] rowCounts = new int[height];
        int[] colCounts = new int[width];

        for (int y = 0; y < height; y++) {
            int rowOffset = y * width;
            for (int x = 0; x < width; x++) {
                if (!result[rowOffset + x]) {
                    continue;
                }

                rowCounts[y]++;
                colCounts[x]++;
            }
        }

        int denseRowThreshold = Math.Max(1, (int)Math.Round(width * 0.90));
        int denseColThreshold = Math.Max(1, (int)Math.Round(height * 0.90));

        bool[] denseRows = new bool[height];
        bool[] denseCols = new bool[width];

        for (int y = 0; y < height; y++) {
            denseRows[y] = rowCounts[y] >= denseRowThreshold;
        }

        for (int x = 0; x < width; x++) {
            denseCols[x] = colCounts[x] >= denseColThreshold;
        }

        // Remove thin near-full-span horizontal strokes.
        for (int y = 0; y < height;) {
            if (!denseRows[y]) {
                y++;
                continue;
            }

            int start = y;
            while (y < height && denseRows[y]) {
                y++;
            }
            int end = y - 1;
            int runLength = end - start + 1;

            if (runLength > 3) {
                continue;
            }

            for (int yy = start; yy <= end; yy++) {
                int rowOffset = yy * width;
                for (int x = 0; x < width; x++) {
                    result[rowOffset + x] = false;
                }
            }
        }

        // Remove thin near-full-span vertical strokes.
        for (int x = 0; x < width;) {
            if (!denseCols[x]) {
                x++;
                continue;
            }

            int start = x;
            while (x < width && denseCols[x]) {
                x++;
            }
            int end = x - 1;
            int runLength = end - start + 1;

            if (runLength > 3) {
                continue;
            }

            for (int xx = start; xx <= end; xx++) {
                for (int y = 0; y < height; y++) {
                    result[y * width + xx] = false;
                }
            }
        }

        return result;
    }

    private sealed class FrameMaskComponent {
        public List<int> Pixels = new List<int>();
        public int Area;
        public int MinX = int.MaxValue;
        public int MinY = int.MaxValue;
        public int MaxX = int.MinValue;
        public int MaxY = int.MinValue;
        public double CenterX;
        public double CenterY;
    }

    private static bool[] KeepDominantSubjectComponent(bool[] source, int width, int height) {
        bool[] visited = new bool[source.Length];
        List<FrameMaskComponent> components = new List<FrameMaskComponent>();
        int[] queue = new int[source.Length];

        for (int i = 0; i < source.Length; i++) {
            if (!source[i] || visited[i]) {
                continue;
            }

            FrameMaskComponent comp = new FrameMaskComponent();
            int head = 0;
            int tail = 0;
            queue[tail++] = i;
            visited[i] = true;

            while (head < tail) {
                int idx = queue[head++];
                int x = idx % width;
                int y = idx / width;

                comp.Pixels.Add(idx);
                comp.Area++;
                if (x < comp.MinX) comp.MinX = x;
                if (x > comp.MaxX) comp.MaxX = x;
                if (y < comp.MinY) comp.MinY = y;
                if (y > comp.MaxY) comp.MaxY = y;

                for (int dy = -1; dy <= 1; dy++) {
                    for (int dx = -1; dx <= 1; dx++) {
                        if (dx == 0 && dy == 0) {
                            continue;
                        }

                        int nx = x + dx;
                        int ny = y + dy;
                        if (nx < 0 || ny < 0 || nx >= width || ny >= height) {
                            continue;
                        }

                        int ni = ny * width + nx;
                        if (!source[ni] || visited[ni]) {
                            continue;
                        }

                        visited[ni] = true;
                        queue[tail++] = ni;
                    }
                }
            }

            comp.CenterX = comp.MinX + ((comp.MaxX - comp.MinX + 1) / 2.0);
            comp.CenterY = comp.MinY + ((comp.MaxY - comp.MinY + 1) / 2.0);
            components.Add(comp);
        }

        if (components.Count <= 1) {
            return source;
        }

        int totalArea = components.Sum(c => c.Area);
        FrameMaskComponent dominant = components.OrderByDescending(c => c.Area).First();

        // If no clear dominant subject exists, do not alter the mask.
        if (dominant.Area < Math.Max(140, (int)Math.Round(totalArea * 0.35))) {
            return source;
        }

        bool[] keep = new bool[source.Length];
        foreach (int p in dominant.Pixels) {
            keep[p] = true;
        }

        foreach (FrameMaskComponent comp in components) {
            if (object.ReferenceEquals(comp, dominant)) {
                continue;
            }

            int horizontalGap = 0;
            if (comp.MaxX < dominant.MinX) {
                horizontalGap = dominant.MinX - comp.MaxX - 1;
            }
            else if (dominant.MaxX < comp.MinX) {
                horizontalGap = comp.MinX - dominant.MaxX - 1;
            }

            int verticalGap = 0;
            if (comp.MaxY < dominant.MinY) {
                verticalGap = dominant.MinY - comp.MaxY - 1;
            }
            else if (dominant.MaxY < comp.MinY) {
                verticalGap = comp.MinY - dominant.MaxY - 1;
            }

            bool tinyNearbyAttachment = comp.Area <= Math.Max(140, (int)Math.Round(dominant.Area * 0.18))
                && horizontalGap <= 12
                && verticalGap <= 16;

            if (!tinyNearbyAttachment) {
                continue;
            }

            foreach (int p in comp.Pixels) {
                keep[p] = true;
            }
        }

        return keep;
    }

    private static bool[] RemoveTinyMaskComponents(bool[] source, int width, int height, int minArea) {
        if (minArea <= 1) {
            return source;
        }

        bool[] visited = new bool[source.Length];
        bool[] result = new bool[source.Length];
        int[] queue = new int[source.Length];

        for (int i = 0; i < source.Length; i++) {
            if (!source[i] || visited[i]) {
                continue;
            }

            int head = 0;
            int tail = 0;
            queue[tail++] = i;
            visited[i] = true;

            List<int> pixels = new List<int>();

            while (head < tail) {
                int idx = queue[head++];
                int x = idx % width;
                int y = idx / width;
                pixels.Add(idx);

                for (int dy = -1; dy <= 1; dy++) {
                    for (int dx = -1; dx <= 1; dx++) {
                        if (dx == 0 && dy == 0) {
                            continue;
                        }

                        int nx = x + dx;
                        int ny = y + dy;
                        if (nx < 0 || ny < 0 || nx >= width || ny >= height) {
                            continue;
                        }

                        int ni = ny * width + nx;
                        if (!source[ni] || visited[ni]) {
                            continue;
                        }

                        visited[ni] = true;
                        queue[tail++] = ni;
                    }
                }
            }

            if (pixels.Count < minArea) {
                continue;
            }

            foreach (int p in pixels) {
                result[p] = true;
            }
        }

        return result;
    }

    private static bool[] PruneThinMaskStrokes(bool[] source, int width, int height, int minNeighbors, int passes) {
        if (passes <= 0) {
            return source;
        }

        bool[] current = source;
        for (int pass = 0; pass < passes; pass++) {
            bool[] next = new bool[current.Length];

            for (int y = 0; y < height; y++) {
                for (int x = 0; x < width; x++) {
                    int idx = y * width + x;
                    if (!current[idx]) {
                        continue;
                    }

                    int neighbors = 0;
                    for (int dy = -1; dy <= 1; dy++) {
                        for (int dx = -1; dx <= 1; dx++) {
                            if (dx == 0 && dy == 0) {
                                continue;
                            }

                            int nx = x + dx;
                            int ny = y + dy;
                            if (nx < 0 || ny < 0 || nx >= width || ny >= height) {
                                continue;
                            }

                            if (current[ny * width + nx]) {
                                neighbors++;
                            }
                        }
                    }

                    if (neighbors >= minNeighbors) {
                        next[idx] = true;
                    }
                }
            }

            current = next;
        }

        return current;
    }

    private static bool[] BuildForegroundMask(Bitmap bmp, Color bg, int distanceThreshold, int spreadThreshold, int pruneMinNeighbors, int prunePasses) {
        int w = bmp.Width;
        int h = bmp.Height;
        bool[] mask = new bool[w * h];
        int thresholdSquared = distanceThreshold * distanceThreshold;

        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                Color p = bmp.GetPixel(x, y);
                if (IsForeground(p, bg.R, bg.G, bg.B, thresholdSquared, spreadThreshold)) {
                    mask[y * w + x] = true;
                }
            }
        }

        // Remove thin grid/text strokes that connect large background regions.
        if (prunePasses <= 0) {
            return RemoveDenseGuideLines(mask, w, h);
        }

        bool[] pruned = PruneThinPixels(mask, w, h, Math.Max(0, pruneMinNeighbors), prunePasses);
        return RemoveDenseGuideLines(pruned, w, h);
    }

    private static bool[] RemoveDenseGuideLines(bool[] source, int width, int height) {
        bool[] result = new bool[source.Length];
        Array.Copy(source, result, source.Length);

        int[] rowCounts = new int[height];
        int[] colCounts = new int[width];

        for (int y = 0; y < height; y++) {
            int rowOffset = y * width;
            for (int x = 0; x < width; x++) {
                if (!result[rowOffset + x]) {
                    continue;
                }

                rowCounts[y]++;
                colCounts[x]++;
            }
        }

        // Remove near-full-width/height strokes that usually come from panel/grid guides.
        int denseRowThreshold = Math.Max(1, (int)Math.Round(width * 0.72));
        int denseColThreshold = Math.Max(1, (int)Math.Round(height * 0.80));

        bool[] denseRows = new bool[height];
        bool[] denseCols = new bool[width];

        for (int y = 0; y < height; y++) {
            denseRows[y] = rowCounts[y] >= denseRowThreshold;
        }

        for (int x = 0; x < width; x++) {
            denseCols[x] = colCounts[x] >= denseColThreshold;
        }

        // Remove only thin dense bands (typical 1-3px guide lines), not wide dense blocks.
        for (int y = 0; y < height;) {
            if (!denseRows[y]) {
                y++;
                continue;
            }

            int start = y;
            while (y < height && denseRows[y]) {
                y++;
            }
            int end = y - 1;
            int runLength = end - start + 1;

            if (runLength > 3) {
                continue;
            }

            for (int yy = start; yy <= end; yy++) {
                int rowOffset = yy * width;
                for (int x = 0; x < width; x++) {
                    result[rowOffset + x] = false;
                }
            }
        }

        for (int x = 0; x < width;) {
            if (!denseCols[x]) {
                x++;
                continue;
            }

            int start = x;
            while (x < width && denseCols[x]) {
                x++;
            }
            int end = x - 1;
            int runLength = end - start + 1;

            if (runLength > 3) {
                continue;
            }

            for (int xx = start; xx <= end; xx++) {
                for (int y = 0; y < height; y++) {
                    result[y * width + xx] = false;
                }
            }
        }

        return result;
    }

    private static bool[] PruneThinPixels(bool[] source, int width, int height, int minNeighbors, int passes) {
        bool[] current = source;

        for (int pass = 0; pass < passes; pass++) {
            bool[] next = new bool[current.Length];

            for (int y = 0; y < height; y++) {
                for (int x = 0; x < width; x++) {
                    int idx = y * width + x;
                    if (!current[idx]) {
                        continue;
                    }

                    int neighbors = 0;
                    for (int dy = -1; dy <= 1; dy++) {
                        for (int dx = -1; dx <= 1; dx++) {
                            if (dx == 0 && dy == 0) {
                                continue;
                            }

                            int nx = x + dx;
                            int ny = y + dy;
                            if (nx < 0 || ny < 0 || nx >= width || ny >= height) {
                                continue;
                            }

                            if (current[ny * width + nx]) {
                                neighbors++;
                            }
                        }
                    }

                    if (neighbors >= minNeighbors) {
                        next[idx] = true;
                    }
                }
            }

            current = next;
        }

        return current;
    }

    private static bool IsForeground(Color p, int bgR, int bgG, int bgB, int thresholdSquared, int spreadThreshold) {
        if (p.A < 8) {
            return false;
        }

        int dr = p.R - bgR;
        int dg = p.G - bgG;
        int db = p.B - bgB;
        int distSquared = (dr * dr) + (dg * dg) + (db * db);

        int max = Math.Max(p.R, Math.Max(p.G, p.B));
        int min = Math.Min(p.R, Math.Min(p.G, p.B));
        int spread = max - min;

        // Pixel is foreground if:
        // 1. It differs significantly from background color (distance threshold)
        // 2. OR it has significant color variation (spread threshold)
        // 3. AND it's not nearly white (avoid picking up light backgrounds as sprites)
        
        bool colorDifferent = distSquared >= thresholdSquared || spread >= spreadThreshold;
        
        // Exclude near-white pixels that might be background
        if (p.R > 240 && p.G > 240 && p.B > 240) {
            return false;  // Skip light gray/white background areas
        }
        
        return colorDifferent;
    }

    private static Color GetBorderMedianColor(Bitmap bmp, int step) {
        List<int> rs = new List<int>();
        List<int> gs = new List<int>();
        List<int> bs = new List<int>();

        int w = bmp.Width;
        int h = bmp.Height;

        for (int x = 0; x < w; x += step) {
            Color top = bmp.GetPixel(x, 0);
            Color bottom = bmp.GetPixel(x, h - 1);
            rs.Add(top.R); gs.Add(top.G); bs.Add(top.B);
            rs.Add(bottom.R); gs.Add(bottom.G); bs.Add(bottom.B);
        }

        for (int y = 0; y < h; y += step) {
            Color left = bmp.GetPixel(0, y);
            Color right = bmp.GetPixel(w - 1, y);
            rs.Add(left.R); gs.Add(left.G); bs.Add(left.B);
            rs.Add(right.R); gs.Add(right.G); bs.Add(right.B);
        }

        rs.Sort(); gs.Sort(); bs.Sort();
        int mid = rs.Count / 2;

        return Color.FromArgb(rs[mid], gs[mid], bs[mid]);
    }

    private static SpriteComponentV7[] FindComponents(bool[] mask, int width, int height, int minArea) {
        bool[] visited = new bool[mask.Length];
        List<SpriteComponentV7> components = new List<SpriteComponentV7>();

        int[] queueX = new int[mask.Length];
        int[] queueY = new int[mask.Length];

        for (int y = 0; y < height; y++) {
            for (int x = 0; x < width; x++) {
                int startIndex = y * width + x;
                if (!mask[startIndex] || visited[startIndex]) {
                    continue;
                }

                int head = 0;
                int tail = 0;

                queueX[tail] = x;
                queueY[tail] = y;
                tail++;
                visited[startIndex] = true;

                int area = 0;
                int minX = x;
                int minY = y;
                int maxX = x;
                int maxY = y;

                while (head < tail) {
                    int cx = queueX[head];
                    int cy = queueY[head];
                    head++;

                    area++;
                    if (cx < minX) minX = cx;
                    if (cy < minY) minY = cy;
                    if (cx > maxX) maxX = cx;
                    if (cy > maxY) maxY = cy;

                    for (int dy = -1; dy <= 1; dy++) {
                        for (int dx = -1; dx <= 1; dx++) {
                            if (dx == 0 && dy == 0) {
                                continue;
                            }

                            int nx = cx + dx;
                            int ny = cy + dy;
                            if (nx < 0 || ny < 0 || nx >= width || ny >= height) {
                                continue;
                            }

                            int ni = ny * width + nx;
                            if (mask[ni] && !visited[ni]) {
                                visited[ni] = true;
                                queueX[tail] = nx;
                                queueY[tail] = ny;
                                tail++;
                            }
                        }
                    }
                }

                if (area < minArea) {
                    continue;
                }

                int bboxWidth = maxX - minX + 1;
                int bboxHeight = maxY - minY + 1;
                if (bboxWidth <= 0 || bboxHeight <= 0) {
                    continue;
                }

                List<SpriteComponentV7> candidates = new List<SpriteComponentV7>();
                bool looksMergedStrip = bboxWidth >= 240 && ((double)bboxWidth / (double)bboxHeight) >= 1.9;

                if (looksMergedStrip) {
                    List<SpriteComponentV7> split = SplitMergedWideComponent(mask, width, minX, minY, maxX, maxY, Math.Max(220, minArea / 3));
                    if (split.Count > 1) {
                        candidates.AddRange(split);
                    }
                }

                if (candidates.Count == 0) {
                    candidates.Add(new SpriteComponentV7 {
                        X = minX,
                        Y = minY,
                        Width = bboxWidth,
                        Height = bboxHeight,
                        Area = area
                    });
                }

                foreach (SpriteComponentV7 candidate in candidates) {
                    if (candidate.Width <= 0 || candidate.Height <= 0) {
                        continue;
                    }

                    double fill = (double)candidate.Area / (double)(candidate.Width * candidate.Height);
                    double ratio = (double)candidate.Width / (double)candidate.Height;

                    // Filter out labels, text, and small UI elements.
                    if (candidate.Height < 60) {
                        continue;
                    }

                    if (candidate.Width < 30 || candidate.Height < 60) {
                        continue;
                    }

                    if (ratio > 3.0 && candidate.Height < 100) {
                        continue;
                    }

                    if (fill < 0.15) {
                        continue;
                    }

                    // Reject wide low-fill strips that are usually guide lines/background bands.
                    if (candidate.Width > 220 && candidate.Height < 190 && fill < 0.45) {
                        continue;
                    }

                    if (ratio > 2.8 && fill < 0.55) {
                        continue;
                    }

                    candidate.Fill = Math.Round(fill, 4);
                    candidate.CenterX = Math.Round(candidate.X + (candidate.Width / 2.0), 2);
                    candidate.CenterY = Math.Round(candidate.Y + (candidate.Height / 2.0), 2);
                    components.Add(candidate);
                }
            }
        }

        return components.ToArray();
    }

    private static List<SpriteComponentV7> SplitMergedWideComponent(bool[] mask, int imageWidth, int minX, int minY, int maxX, int maxY, int minSegmentArea) {
        List<SpriteComponentV7> split = new List<SpriteComponentV7>();

        int boxWidth = maxX - minX + 1;
        int boxHeight = maxY - minY + 1;

        if (boxWidth < 240 || boxHeight < 60) {
            return split;
        }

        int[] columnCounts = new int[boxWidth];
        int activeThreshold = Math.Max(2, (int)Math.Round(boxHeight * 0.03));

        for (int x = 0; x < boxWidth; x++) {
            int globalX = minX + x;
            int count = 0;

            for (int y = minY; y <= maxY; y++) {
                if (mask[y * imageWidth + globalX]) {
                    count++;
                }
            }

            columnCounts[x] = count;
        }

        bool[] activeCols = new bool[boxWidth];
        for (int x = 0; x < boxWidth; x++) {
            activeCols[x] = columnCounts[x] >= activeThreshold;
        }

        // Fill tiny gaps to avoid splitting one frame due to a 1-2px empty seam.
        for (int x = 1; x < boxWidth - 1; x++) {
            if (!activeCols[x] && activeCols[x - 1] && activeCols[x + 1]) {
                activeCols[x] = true;
            }
        }

        int runStart = -1;
        for (int x = 0; x <= boxWidth; x++) {
            bool active = x < boxWidth && activeCols[x];

            if (active && runStart < 0) {
                runStart = x;
                continue;
            }

            if (active || runStart < 0) {
                continue;
            }

            int segStartLocal = runStart;
            int runEnd = x - 1;
            int runWidth = runEnd - runStart + 1;
            runStart = -1;

            if (runWidth < 24) {
                continue;
            }

            int segMinX = minX + segStartLocal;
            int segMaxX = minX + runEnd;
            int segMinY = int.MaxValue;
            int segMaxY = int.MinValue;
            int segArea = 0;

            for (int yy = minY; yy <= maxY; yy++) {
                for (int xx = segMinX; xx <= segMaxX; xx++) {
                    if (!mask[yy * imageWidth + xx]) {
                        continue;
                    }

                    segArea++;
                    if (yy < segMinY) segMinY = yy;
                    if (yy > segMaxY) segMaxY = yy;
                }
            }

            if (segArea < minSegmentArea || segMaxY < segMinY) {
                continue;
            }

            split.Add(new SpriteComponentV7 {
                X = segMinX,
                Y = segMinY,
                Width = segMaxX - segMinX + 1,
                Height = segMaxY - segMinY + 1,
                Area = segArea
            });
        }

        if (split.Count > 1) {
            return split;
        }

        // Fallback: split by low-density valleys when there are no empty-column gaps.
        split.Clear();

        int[] smooth = new int[boxWidth];
        for (int x = 0; x < boxWidth; x++) {
            int sum = 0;
            int samples = 0;
            for (int k = -2; k <= 2; k++) {
                int ix = x + k;
                if (ix < 0 || ix >= boxWidth) {
                    continue;
                }

                sum += columnCounts[ix];
                samples++;
            }

            smooth[x] = samples > 0 ? (sum / samples) : columnCounts[x];
        }

        int[] sorted = new int[boxWidth];
        Array.Copy(smooth, sorted, boxWidth);
        Array.Sort(sorted);
        int high = sorted[Math.Max(0, (int)Math.Floor((sorted.Length - 1) * 0.85))];
        int valleyThreshold = Math.Max(2, (int)Math.Round(high * 0.55));

        List<int> cuts = new List<int>();
        int lastCut = -9999;

        for (int x = 2; x < boxWidth - 2; x++) {
            bool isValley = smooth[x] <= valleyThreshold && smooth[x] <= smooth[x - 1] && smooth[x] <= smooth[x + 1];
            if (!isValley) {
                continue;
            }

            if (x - lastCut < 55) {
                continue;
            }

            cuts.Add(x);
            lastCut = x;
        }

        if (cuts.Count == 0) {
            // Last fallback: split wide strip into roughly equal cells.
            int estimatedFrames = (int)Math.Round((double)boxWidth / Math.Max(80.0, boxHeight * 0.9));
            estimatedFrames = Math.Max(3, Math.Min(6, estimatedFrames));

            int baseWidth = boxWidth / estimatedFrames;
            int remainder = boxWidth % estimatedFrames;
            int start = 0;

            for (int i = 0; i < estimatedFrames; i++) {
                int localStart = start;
                int localWidth = baseWidth + (i < remainder ? 1 : 0);
                int localEnd = localStart + localWidth - 1;
                start = localEnd + 1;

                if (localWidth < 36) {
                    continue;
                }

                int segMinX = minX + localStart;
                int segMaxX = minX + localEnd;
                int segMinY = int.MaxValue;
                int segMaxY = int.MinValue;
                int segArea = 0;

                for (int yy = minY; yy <= maxY; yy++) {
                    for (int xx = segMinX; xx <= segMaxX; xx++) {
                        if (!mask[yy * imageWidth + xx]) {
                            continue;
                        }

                        segArea++;
                        if (yy < segMinY) segMinY = yy;
                        if (yy > segMaxY) segMaxY = yy;
                    }
                }

                if (segArea < minSegmentArea || segMaxY < segMinY) {
                    continue;
                }

                split.Add(new SpriteComponentV7 {
                    X = segMinX,
                    Y = segMinY,
                    Width = segMaxX - segMinX + 1,
                    Height = segMaxY - segMinY + 1,
                    Area = segArea
                });
            }

            return split;
        }

        int prev = 0;
        foreach (int cut in cuts) {
            int localStart = prev;
            int localEnd = cut;
            prev = cut + 1;

            int segWidth = localEnd - localStart + 1;
            if (segWidth < 36) {
                continue;
            }

            int segMinX = minX + localStart;
            int segMaxX = minX + localEnd;
            int segMinY = int.MaxValue;
            int segMaxY = int.MinValue;
            int segArea = 0;

            for (int yy = minY; yy <= maxY; yy++) {
                for (int xx = segMinX; xx <= segMaxX; xx++) {
                    if (!mask[yy * imageWidth + xx]) {
                        continue;
                    }

                    segArea++;
                    if (yy < segMinY) segMinY = yy;
                    if (yy > segMaxY) segMaxY = yy;
                }
            }

            if (segArea < minSegmentArea || segMaxY < segMinY) {
                continue;
            }

            split.Add(new SpriteComponentV7 {
                X = segMinX,
                Y = segMinY,
                Width = segMaxX - segMinX + 1,
                Height = segMaxY - segMinY + 1,
                Area = segArea
            });
        }

        int tailStart = prev;
        int tailWidth = boxWidth - tailStart;
        if (tailWidth >= 36) {
            int segMinX = minX + tailStart;
            int segMaxX = maxX;
            int segMinY = int.MaxValue;
            int segMaxY = int.MinValue;
            int segArea = 0;

            for (int yy = minY; yy <= maxY; yy++) {
                for (int xx = segMinX; xx <= segMaxX; xx++) {
                    if (!mask[yy * imageWidth + xx]) {
                        continue;
                    }

                    segArea++;
                    if (yy < segMinY) segMinY = yy;
                    if (yy > segMaxY) segMaxY = yy;
                }
            }

            if (segArea >= minSegmentArea && segMaxY >= segMinY) {
                split.Add(new SpriteComponentV7 {
                    X = segMinX,
                    Y = segMinY,
                    Width = segMaxX - segMinX + 1,
                    Height = segMaxY - segMinY + 1,
                    Area = segArea
                });
            }
        }

        return split;
    }
}
"@
}

function Get-FirstSpriteFile {
    param([string]$DirectoryPath)

    $candidates = Get-ChildItem -Path $DirectoryPath -File |
        Where-Object { $_.Extension -match '^\.(png|PNG)$' } |
        Sort-Object Name

    if (-not $candidates) {
        return $null
    }

    $preferred = $candidates | Where-Object { $_.BaseName -match 'sprite' } | Select-Object -First 1
    if ($preferred) {
        return $preferred
    }

    return $candidates | Select-Object -First 1
}

function Merge-FragmentedComponents {
    param([object[]]$Components)

    if (-not $Components -or $Components.Count -eq 0) {
        return @()
    }

    $items = @($Components | ForEach-Object {
        [PSCustomObject]@{
            X = [int]$_.X
            Y = [int]$_.Y
            Width = [int]$_.Width
            Height = [int]$_.Height
            Area = [int]$_.Area
            Fill = [double]$_.Fill
            CenterX = [double]$_.CenterX
            CenterY = [double]$_.CenterY
        }
    })

    $changed = $true
    while ($changed) {
        $changed = $false

        for ($i = 0; $i -lt $items.Count -and -not $changed; $i += 1) {
            for ($j = $i + 1; $j -lt $items.Count; $j += 1) {
                $a = $items[$i]
                $b = $items[$j]

                $aLeft = [int]$a.X
                $aRight = [int]($a.X + $a.Width - 1)
                $aTop = [int]$a.Y
                $aBottom = [int]($a.Y + $a.Height - 1)

                $bLeft = [int]$b.X
                $bRight = [int]($b.X + $b.Width - 1)
                $bTop = [int]$b.Y
                $bBottom = [int]($b.Y + $b.Height - 1)

                $overlapLeft = [Math]::Max($aLeft, $bLeft)
                $overlapRight = [Math]::Min($aRight, $bRight)
                $overlapW = [Math]::Max(0, $overlapRight - $overlapLeft + 1)
                $minWidth = [Math]::Max(1, [Math]::Min([int]$a.Width, [int]$b.Width))
                $xOverlapRatio = [double]$overlapW / [double]$minWidth

                $verticalGap = 0
                if ($aBottom -lt $bTop) {
                    $verticalGap = $bTop - $aBottom - 1
                }
                elseif ($bBottom -lt $aTop) {
                    $verticalGap = $aTop - $bBottom - 1
                }

                $closeInX = [Math]::Abs([double]$a.CenterX - [double]$b.CenterX) -le [Math]::Max([int]$a.Width, [int]$b.Width) * 0.35
                $shouldMerge = ($xOverlapRatio -ge 0.40 -or $closeInX) -and $verticalGap -ge 0 -and $verticalGap -le 14

                if (-not $shouldMerge) {
                    continue
                }

                $newX = [Math]::Min($aLeft, $bLeft)
                $newY = [Math]::Min($aTop, $bTop)
                $newRight = [Math]::Max($aRight, $bRight)
                $newBottom = [Math]::Max($aBottom, $bBottom)
                $newW = $newRight - $newX + 1
                $newH = $newBottom - $newY + 1
                $newArea = [int]$a.Area + [int]$b.Area
                $newFill = [Math]::Round([double]$newArea / [double]([Math]::Max(1, $newW * $newH)), 4)

                $merged = [PSCustomObject]@{
                    X = $newX
                    Y = $newY
                    Width = $newW
                    Height = $newH
                    Area = $newArea
                    Fill = $newFill
                    CenterX = [Math]::Round($newX + ($newW / 2.0), 2)
                    CenterY = [Math]::Round($newY + ($newH / 2.0), 2)
                }

                $items = @($items | Where-Object { $_ -ne $a -and $_ -ne $b })
                $items += $merged
                $changed = $true
                break
            }
        }
    }

    return @($items)
}

function Group-ComponentsIntoRows {
    param([object[]]$Components)

    if (-not $Components -or $Components.Count -eq 0) {
        return @()
    }

    $heights = @($Components | ForEach-Object { [int]$_.Height } | Sort-Object)
    $medianHeight = $heights[[Math]::Floor($heights.Count / 2)]
    $rowTolerance = [Math]::Max(36, [int]([double]$medianHeight * 0.65))

    $rows = @()
    $sorted = $Components | Sort-Object CenterY, CenterX

    foreach ($component in $sorted) {
        $assigned = $false

        for ($i = 0; $i -lt $rows.Count; $i += 1) {
            if ([Math]::Abs($component.CenterY - $rows[$i].AverageY) -le $rowTolerance) {
                $rows[$i].Items += $component
                $rows[$i].AverageY = [Math]::Round((($rows[$i].AverageY * ($rows[$i].Items.Count - 1)) + $component.CenterY) / $rows[$i].Items.Count, 2)
                $assigned = $true
                break
            }
        }

        if (-not $assigned) {
            $rows += [PSCustomObject]@{
                AverageY = $component.CenterY
                Items = @($component)
            }
        }
    }

    foreach ($row in $rows) {
        $sortedItems = @($row.Items | Sort-Object CenterX)
        $deduped = @()

        foreach ($candidate in $sortedItems) {
            $isDuplicate = $false

            foreach ($existing in $deduped) {
                $left = [Math]::Max([int]$candidate.X, [int]$existing.X)
                $top = [Math]::Max([int]$candidate.Y, [int]$existing.Y)
                $right = [Math]::Min(([int]$candidate.X + [int]$candidate.Width), ([int]$existing.X + [int]$existing.Width))
                $bottom = [Math]::Min(([int]$candidate.Y + [int]$candidate.Height), ([int]$existing.Y + [int]$existing.Height))

                $overlapW = [Math]::Max(0, $right - $left)
                $overlapH = [Math]::Max(0, $bottom - $top)
                if ($overlapW -le 0 -or $overlapH -le 0) {
                    continue
                }

                $intersection = $overlapW * $overlapH
                $candArea = [Math]::Max(1, [int]$candidate.Width * [int]$candidate.Height)
                $existingArea = [Math]::Max(1, [int]$existing.Width * [int]$existing.Height)
                $minArea = [Math]::Max(1, [Math]::Min($candArea, $existingArea))
                $overlapRatioToSmaller = [double]$intersection / [double]$minArea

                if ($overlapRatioToSmaller -ge 0.78) {
                    if ([int]$candidate.Area -gt [int]$existing.Area) {
                        $deduped = @($deduped | Where-Object { $_ -ne $existing })
                    }
                    else {
                        $isDuplicate = $true
                    }
                    break
                }
            }

            if (-not $isDuplicate) {
                $deduped += $candidate
            }
        }

        $row.Items = @($deduped | Sort-Object CenterX)
    }

    return @($rows | Sort-Object AverageY)
}

function Split-ComponentIntoColumns {
    param(
        [object]$Component,
        [int]$Columns
    )

    if (-not $Component) {
        return @()
    }

    if ($Columns -lt 2) {
        return @($Component)
    }

    $totalWidth = [int]$Component.Width
    $startX = [int]$Component.X
    $height = [int]$Component.Height
    $startY = [int]$Component.Y
    $baseWidth = [Math]::Floor([double]$totalWidth / [double]$Columns)
    $remainder = $totalWidth % $Columns

    if ($baseWidth -lt 16) {
        return @($Component)
    }

    $parts = @()
    $cursor = $startX

    for ($i = 0; $i -lt $Columns; $i += 1) {
        $partWidth = [int]$baseWidth
        if ($i -lt $remainder) {
            $partWidth += 1
        }

        if ($partWidth -lt 12) {
            continue
        }

        $partArea = [int][Math]::Max(1, [Math]::Round(([double]$Component.Area * [double]$partWidth) / [double]$totalWidth))
        $partFill = [Math]::Round([double]$partArea / [double]([Math]::Max(1, $partWidth * $height)), 4)

        $parts += [PSCustomObject]@{
            X = $cursor
            Y = $startY
            Width = $partWidth
            Height = $height
            Area = $partArea
            Fill = $partFill
            CenterX = [Math]::Round($cursor + ($partWidth / 2.0), 2)
            CenterY = [Math]::Round($startY + ($height / 2.0), 2)
        }

        $cursor += $partWidth
    }

    return @($parts)
}

if (-not (Test-Path -Path $SpritesRoot)) {
    throw "Sprites root not found: $SpritesRoot"
}

$characterDirs = Get-ChildItem -Path $SpritesRoot -Directory | Sort-Object Name
if (-not $characterDirs) {
    Write-Host "No character directories found under $SpritesRoot"
    exit 0
}

if ($Characters -and $Characters.Count -gt 0) {
    $requested = $Characters | ForEach-Object { $_.ToLowerInvariant() }
    $characterDirs = $characterDirs | Where-Object { $requested -contains $_.Name.ToLowerInvariant() }

    if (-not $characterDirs) {
        Write-Warning "No matching character directories found for requested names."
        exit 0
    }
}

foreach ($characterDir in $characterDirs) {
    $spriteFile = Get-FirstSpriteFile -DirectoryPath $characterDir.FullName
    if (-not $spriteFile) {
        Write-Warning "Skipping $($characterDir.Name): no PNG sprite file found."
        continue
    }

    Write-Host "Processing $($characterDir.Name): $($spriteFile.Name)"

    $framesRoot = Join-Path $characterDir.FullName "frames"
    if ($CleanOutput -and (Test-Path $framesRoot)) {
        Remove-Item -Path $framesRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $framesRoot -Force | Out-Null

    $analysis = [SpriteSheetExtractorV7]::Analyze(
        $spriteFile.FullName,
        $BackgroundDistanceThreshold,
        $ColorSpreadThreshold,
        $MinComponentArea,
        20,
        $PruneMinNeighbors,
        $PrunePasses,
        $ForceBackgroundR,
        $ForceBackgroundG,
        $ForceBackgroundB
    )

    if (-not $analysis.Components -or $analysis.Components.Count -eq 0) {
        Write-Warning "No usable sprite components found for $($characterDir.Name)."
        continue
    }

    $mergedComponents = @(Merge-FragmentedComponents -Components $analysis.Components)
    $rows = @(Group-ComponentsIntoRows -Components $mergedComponents)
    $metadataRows = @()

    for ($rowIndex = 0; $rowIndex -lt $rows.Count; $rowIndex += 1) {
        $sequenceName = "sequence-{0}" -f ($rowIndex + 1).ToString("00")
        $sequenceDir = Join-Path $framesRoot $sequenceName
        New-Item -ItemType Directory -Path $sequenceDir -Force | Out-Null

        $frames = @()
        $rowItems = @($rows[$rowIndex].Items)

        if (
            -not [string]::IsNullOrWhiteSpace($ForceSplitCharacter) -and
            $characterDir.Name.Equals($ForceSplitCharacter, [System.StringComparison]::OrdinalIgnoreCase) -and
            $ForceSplitSequence -eq ($rowIndex + 1)
        ) {
            $splitColumns = if ($ForceSplitColumns -ge 2) { $ForceSplitColumns } else { 4 }

            if ($ForceSplitUseRowBounds -and $rowItems.Count -gt 1) {
                $minX = ($rowItems | Measure-Object -Property X -Minimum).Minimum
                $minY = ($rowItems | Measure-Object -Property Y -Minimum).Minimum
                $maxRight = ($rowItems | ForEach-Object { [int]$_.X + [int]$_.Width - 1 } | Measure-Object -Maximum).Maximum
                $maxBottom = ($rowItems | ForEach-Object { [int]$_.Y + [int]$_.Height - 1 } | Measure-Object -Maximum).Maximum
                $sumArea = ($rowItems | Measure-Object -Property Area -Sum).Sum

                $unionComponent = [PSCustomObject]@{
                    X = [int]$minX
                    Y = [int]$minY
                    Width = [int]($maxRight - $minX + 1)
                    Height = [int]($maxBottom - $minY + 1)
                    Area = [int]$sumArea
                    Fill = 0.0
                    CenterX = [Math]::Round($minX + (($maxRight - $minX + 1) / 2.0), 2)
                    CenterY = [Math]::Round($minY + (($maxBottom - $minY + 1) / 2.0), 2)
                }

                $rowItems = @(Split-ComponentIntoColumns -Component $unionComponent -Columns $splitColumns)
            }
            else {
                $target = if ($rowItems.Count -gt 0) { $rowItems[0] } else { $null }
                if ($target) {
                    $rowItems = @(Split-ComponentIntoColumns -Component $target -Columns $splitColumns)
                }
            }

            Write-Host "  -> Forced split applied to $($characterDir.Name) $sequenceName into $($rowItems.Count) columns"
        }

        for ($frameIndex = 0; $frameIndex -lt $rowItems.Count; $frameIndex += 1) {
            $component = $rowItems[$frameIndex]
            $frameName = "frame-{0}" -f ($frameIndex + 1).ToString("00")
            $frameFile = "$frameName.png"
            $framePath = Join-Path $sequenceDir $frameFile

            [SpriteSheetExtractorV7]::SaveFrame(
                $spriteFile.FullName,
                $framePath,
                [int]$component.X,
                [int]$component.Y,
                [int]$component.Width,
                [int]$component.Height,
                $Padding,
                [int]$analysis.BackgroundR,
                [int]$analysis.BackgroundG,
                [int]$analysis.BackgroundB,
                $BackgroundDistanceThreshold,
                $ColorSpreadThreshold,
                (
                    -not [string]::IsNullOrWhiteSpace($DisableBorderCleanupCharacter) -and
                    $characterDir.Name.Equals($DisableBorderCleanupCharacter, [System.StringComparison]::OrdinalIgnoreCase) -and
                    $DisableBorderCleanupSequence -eq ($rowIndex + 1)
                )
            )

            $frames += [PSCustomObject]@{
                frame = $frameName
                file = $frameFile
                bbox = [PSCustomObject]@{
                    x = [int]$component.X
                    y = [int]$component.Y
                    width = [int]$component.Width
                    height = [int]$component.Height
                }
                area = [int]$component.Area
                fill = [double]$component.Fill
            }
        }

        $metadataRows += [PSCustomObject]@{
            sequence = $sequenceName
            frameCount = $frames.Count
            frames = $frames
        }
    }

    $metadata = [PSCustomObject]@{
        character = $characterDir.Name
        source = $spriteFile.Name
        backgroundSample = [PSCustomObject]@{
            r = [int]$analysis.BackgroundR
            g = [int]$analysis.BackgroundG
            b = [int]$analysis.BackgroundB
        }
        settings = [PSCustomObject]@{
            backgroundDistanceThreshold = $BackgroundDistanceThreshold
            colorSpreadThreshold = $ColorSpreadThreshold
            minComponentArea = $MinComponentArea
            padding = $Padding
            pruneMinNeighbors = $PruneMinNeighbors
            prunePasses = $PrunePasses
            forceBackground = [PSCustomObject]@{
                r = $ForceBackgroundR
                g = $ForceBackgroundG
                b = $ForceBackgroundB
            }
        }
        sequenceCount = $metadataRows.Count
        sequences = $metadataRows
    }

    $metadata | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $framesRoot "sequence-map.json") -Encoding UTF8
    Write-Host "  -> $($metadataRows.Count) sequences exported to $framesRoot"
}

Write-Host "Sprite sequence extraction completed."





