/**
* Copyright: Copyright Auburn Sounds 2015 and later.
* License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
* Authors:   Guillaume Piolat
*/
module dplug.gui.graphics;

import std.math;
import std.range;
import std.parallelism;
import std.algorithm;

import ae.utils.graphics;

import dplug.plugin.client;
import dplug.plugin.graphics;
import dplug.plugin.daw;

import dplug.gui.window;
import dplug.gui.mipmap;
import dplug.gui.boxlist;
import dplug.gui.toolkit.context;
import dplug.gui.toolkit.element;
import dplug.gui.toolkit.dirtylist;

/// In the whole package:
/// The diffuse maps contains:
///   RGBA = red/green/blue/emissiveness
/// The depth maps contains:
///   RGBA = depth / shininess

// A GUIGraphics is the interface between a plugin client and a IWindow.
// It is also an UIElement and the root element of the plugin UI hierarchy.
// You have to derive it to have a GUI.
// It dispatches window events to the GUI hierarchy.
class GUIGraphics : UIElement, IGraphics
{
    // light 1 used for key lighting and shadows
    // always coming from top-right
    vec3f light1Color;


    // light 2 used for things using the normal
    vec3f light2Dir;
    vec3f light2Color;

    float ambientLight;



    this(int initialWidth, int initialHeight)
    {
        _uiContext = new UIContext();
        super(_uiContext);

        _windowListener = new WindowListener();

        _window = null;
        _askedWidth = initialWidth;
        _askedHeight = initialHeight;

        // defaults
        light1Color = vec3f(0.54f, 0.50f, 0.46f) * 0.4f;

        light2Dir = vec3f(0.0f, 1.0f, 0.1f).normalized;
        light2Color = vec3f(0.378f, 0.35f, 0.322f);
        ambientLight = 0.3f;

        _taskPool = new TaskPool();

        _areasToUpdate = new AlignedBuffer!box2i;

        _updateRectScratch[0] = new AlignedBuffer!box2i;
        _updateRectScratch[1] = new AlignedBuffer!box2i;

        _areasToRender = new AlignedBuffer!box2i;
        _areasToRenderNonOverlapping = new AlignedBuffer!box2i;
        _areasToRenderNonOverlappingTiled = new AlignedBuffer!box2i;

        _elemsToDraw = new AlignedBuffer!UIElement;

        _compositingWatch = new StopWatch("Compositing = ");
    }

    ~this()
    {
        close();
    }

    override void close()
    {
        // TODO make sure this is actually called
        super.close();
        _uiContext.close();

        _areasToUpdate.close();
        _updateRectScratch[0].close();
        _updateRectScratch[1].close();
        _areasToRender.close();
        _areasToRenderNonOverlapping.close();
        _areasToRenderNonOverlappingTiled.close();
        _elemsToDraw.close();
    }

    // Graphics implementation

    override void openUI(void* parentInfo, DAW daw)
    {
        // We create this window each time.
        _window = createWindow(parentInfo, _windowListener, _askedWidth, _askedHeight);

        _uiContext.debugOutput = &_window.debugOutput;

        reflow(box2i(0, 0, _askedWidth, _askedHeight));

        // Sets the whole UI dirty
        setDirty();
    }

    override void closeUI()
    {
        // Destroy window.
        _window.terminate();
    }

    override int getGUIWidth()
    {
        return _askedWidth;
    }

    override int getGUIHeight()
    {
        return _askedHeight;
    }

    class StopWatch
    {
        this(string title)
        {
            _title = title;
        }

        void start()
        {
            _lastTime = _window.getTimeMs();
        }

        void stop()
        {
            uint now = _window.getTimeMs();
            int timeDiff = cast(int)(now - _lastTime);

            if (times > 0)
                sum += timeDiff; // first sample is considered

            times++;
            //string msg = _title ~ to!string(timeDiff) ~ " ms";
            //_window.debugOutput(msg);
        }

        void displayMean()
        {
            if (times > 1)
            {
                string msg = _title ~ to!string(sum / (times - 1)) ~ " ms mean";
                _window.debugOutput(msg);
            }
        }

        string _title;
        uint _lastTime;
        double sum = 0;
        int times = 0;
    }


    // This nested class is only here to avoid name conflicts between
    // UIElement and IWindowListener methods :|
    class WindowListener : IWindowListener
    {
        override bool onMouseClick(int x, int y, MouseButton mb, bool isDoubleClick, MouseState mstate)
        {
            return this.outer.mouseClick(x, y, mb, isDoubleClick, mstate);
        }

        override bool onMouseRelease(int x, int y, MouseButton mb, MouseState mstate)
        {
            this.outer.mouseRelease(x, y, mb, mstate);
            return true;
        }

        override bool onMouseWheel(int x, int y, int wheelDeltaX, int wheelDeltaY, MouseState mstate)
        {
            return this.outer.mouseWheel(x, y, wheelDeltaX, wheelDeltaY, mstate);
        }

        override void onMouseMove(int x, int y, int dx, int dy, MouseState mstate)
        {
            this.outer.mouseMove(x, y, dx, dy, mstate);
        }

        override void recomputeDirtyAreas()
        {
            return this.outer.recomputeDirtyAreas();
        }

        override bool isUIDirty()
        {
            return this.outer.isUIDirty();
        }

        override bool onKeyDown(Key key)
        {
            // Sends the event to the last clicked element first
            if (_uiContext.focused !is null)
                if (_uiContext.focused.onKeyDown(key))
                    return true;

            // else to all Elements
            return keyDown(key);
        }

        override bool onKeyUp(Key key)
        {
            // Sends the event to the last clicked element first
            if (_uiContext.focused !is null)
                if (_uiContext.focused.onKeyUp(key))
                    return true;
            // else to all Elements
            return keyUp(key);
        }

        /// Returns areas affected by updates.
        override box2i getDirtyRectangle() nothrow @nogc
        {
            return _areasToRender[].boundingBox();
        }

        override void onResized(int width, int height)
        {
            _askedWidth = width;
            _askedHeight = height;

            reflow(box2i(0, 0, _askedWidth, _askedHeight));

            _diffuseMap.size(5, width, height);
            _depthMap.size(4, width, height);
        }

        // Redraw dirtied controls in depth and diffuse maps.
        // Update composited cache.
        override void onDraw(ImageRef!RGBA wfb, bool swapRB)
        {
            renderElements();

            // Split boxes to avoid overlapped work
            // Note: this is done separately for update areas and render areas
            _areasToRenderNonOverlapping.clearContents();
            removeOverlappingAreas(_areasToRender[], _areasToRenderNonOverlapping);

            regenerateMipmaps();

            // Composite GUI
            // Most of the cost of rendering is here
            _compositingWatch.start();
            compositeGUI(wfb, swapRB);
            _compositingWatch.stop();
            _compositingWatch.displayMean();

            // only then is the list of rectangles to update cleared
            _areasToUpdate.clearContents();
        }

        override void onMouseCaptureCancelled()
        {
            // Stop an eventual drag operation
            _uiContext.stopDragging();
        }

        override void onAnimate(double dt, double time)
        {
            this.outer.animate(dt, time);
        }
    }

protected:
    UIContext _uiContext;

    WindowListener _windowListener;

    // An interface to the underlying window
    IWindow _window;

    // Task pool for multi-threaded image work
    TaskPool _taskPool;

    int _askedWidth = 0;
    int _askedHeight = 0;

    Mipmap _diffuseMap;
    Mipmap _depthMap;

    // The list of areas whose diffuse/depth data have been changed.
    AlignedBuffer!box2i _areasToUpdate;

    // Same, but temporary variable for mipmap generation
    AlignedBuffer!box2i[2] _updateRectScratch;

    // The list of areas that must be effectively updated in the composite buffer
    // (sligthly larger than _areasToUpdate).
    AlignedBuffer!box2i _areasToRender;

    // same list, but reorganized to avoid overlap
    AlignedBuffer!box2i _areasToRenderNonOverlapping;

    // same list, but separated in smaller tiles
    AlignedBuffer!box2i _areasToRenderNonOverlappingTiled;

    // The list of UIElement to draw
    // Note: AlignedBuffer memory isn't scanned,
    //       but this doesn't matter since UIElement are the UI hierarchy anyway.
    AlignedBuffer!UIElement _elemsToDraw;


    StopWatch _compositingWatch;


    bool isUIDirty() nothrow @nogc
    {
        bool dirtyListEmpty = context().dirtyList.isEmpty();
        return !dirtyListEmpty;
    }

    // Fills _areasToUpdate and _areasToRender
    void recomputeDirtyAreas()
    {
        // Get areas to update
        _areasToRender.clearContents();

        context().dirtyList.pullAllRectangles(_areasToUpdate);

        foreach(dirtyRect; _areasToUpdate)
        {
            assert(dirtyRect.isSorted);
            assert(!dirtyRect.empty);
            _areasToRender.pushBack( extendsDirtyRect(dirtyRect, _askedWidth, _askedHeight) );
        }
    }

    box2i extendsDirtyRect(box2i rect, int width, int height)
    {
        // Tuned by hand on very shiny light sources.
        // Too high and processing becomes very expensive.
        // Too little and the ligth decay doesn't feel natural.

        int xmin = rect.min.x - 30;
        int ymin = rect.min.y - 30;
        int xmax = rect.max.x + 30;
        int ymax = rect.max.y + 30;

        if (xmin < 0) xmin = 0;
        if (ymin < 0) ymin = 0;
        if (xmax > width) xmax = width;
        if (ymax > height) ymax = height;
        return box2i(xmin, ymin, xmax, ymax);
    }

    /// Redraw UIElements
    void renderElements()
    {
        // recompute draw list
        _elemsToDraw.clearContents();
        getDrawList(_elemsToDraw);

        // Sort by ascending z-order (high z-order gets drawn last)
        // This sort must be stable to avoid messing with tree natural order.
        auto elemsToSort = _elemsToDraw[];
        sort!("a.zOrder() < b.zOrder()", SwapStrategy.stable)(elemsToSort);

        enum bool parallelDraw = true;

        auto diffuseRef = _diffuseMap.levels[0].toRef();
        auto depthRef = _depthMap.levels[0].toRef();

        static if (parallelDraw)
        {
            int drawn = 0;
            int maxParallelElements = 8;
            int N = cast(int)_elemsToDraw.length;

            while(drawn < N)
            {
                int canBeDrawn = 1; // at least one can be drawn without collision

                // Search max number of parallelizable draws until the end of the list or a collision is found
                bool foundIntersection = false;
                for ( ; (canBeDrawn < maxParallelElements) && (drawn + canBeDrawn < N); ++canBeDrawn)
                {
                    box2i candidate = _elemsToDraw[drawn + canBeDrawn].position;

                    for (int j = 0; j < canBeDrawn; ++j)
                    {
                        if (_elemsToDraw[drawn + j].position.intersects(candidate))
                        {
                            foundIntersection = true;
                            break;
                        }
                    }
                    if (foundIntersection)
                        break;
                }

                assert(canBeDrawn >= 1 && canBeDrawn <= maxParallelElements);

                // Draw a number of UIElement in parallel, don't use other threads if only one element
                if (canBeDrawn == 1)
                    _elemsToDraw[drawn].render(diffuseRef, depthRef, _areasToUpdate[]);
                else
                    foreach(i; _taskPool.parallel(canBeDrawn.iota))
                        _elemsToDraw[drawn + i].render(diffuseRef, depthRef, _areasToUpdate[]);

                drawn += canBeDrawn;
                assert(drawn <= N);
            }
            assert(drawn == N);
        }
        else
        {
            // Render required areas in diffuse and depth maps, base level
            foreach(elem; _elemsToDraw)
                elem.render(diffuseRef, depthRef, _areasToUpdate[]);
        }
    }

    /// Compose lighting effects from depth and diffuse into a result.
    /// takes output image and non-overlapping areas as input
    /// Useful multithreading code.
    void compositeGUI(ImageRef!RGBA wfb, bool swapRB)
    {
        // Quick subjective testing indicates than somewhere between 16x16 and 32x32 have best performance
        enum tileWidth = 64;
        enum tileHeight = 32;

        _areasToRenderNonOverlappingTiled.clearContents();
        tileAreas(_areasToRenderNonOverlapping[], tileWidth, tileHeight,_areasToRenderNonOverlappingTiled);

        int numAreas = cast(int)_areasToRenderNonOverlappingTiled.length;

        bool parallelCompositing = true;

        if (parallelCompositing)
        {
            foreach(i; _taskPool.parallel(numAreas.iota))
                compositeTile(wfb, swapRB, _areasToRenderNonOverlappingTiled[i]);
        }
        else
        {
            foreach(i; 0..numAreas)
                compositeTile(wfb, swapRB, _areasToRenderNonOverlappingTiled[i]);
        }
    }

    /// Compose lighting effects from depth and diffuse into a result.
    /// takes output image and non-overlapping areas as input
    /// Useful multithreading code.
    void regenerateMipmaps()
    {
        int numAreas = cast(int)_areasToUpdate.length;

        // Fill update rect buffer with the content of _areasToUpdateNonOverlapping
        for (int i = 0; i < 2; ++i)
        {
            _updateRectScratch[i].clearContents();
            _updateRectScratch[i].pushBack(_areasToUpdate[]);
        }

        // We can't use tiled parallelism here because there is overdraw beyond level 0
        // So instead what we do is using up to 2 threads.
        foreach(i; _taskPool.parallel(2.iota))
        {
            Mipmap* mipmap = i == 0 ? &_diffuseMap : &_depthMap;
            if (i == 0)
            {
                // diffuse
                foreach(level; 1 .. mipmap.numLevels())
                {
                    auto quality = level >= 2 ? Mipmap.Quality.cubicAlphaCov : Mipmap.Quality.boxAlphaCov;
                    foreach(ref area; _updateRectScratch[i])
                    {
                        area = mipmap.generateNextLevel(quality, area, level);
                    }
                }
            }
            else
            {
                // depth

                foreach(level; 1 .. mipmap.numLevels())
                {
                    auto quality = level >= 3 ? Mipmap.Quality.cubic : Mipmap.Quality.box;
                    foreach(ref area; _updateRectScratch[i])
                    {
                        area = mipmap.generateNextLevel(quality, area, level);
                    }
                }
            }
        }
    }

    /// Don't like this rendering? Feel free to override this method.
    void compositeTile(ImageRef!RGBA wfb, bool swapRB, box2i area)
    {
        Mipmap* skybox = &context.skybox;
        int w = _diffuseMap.levels[0].w;
        int h = _diffuseMap.levels[0].h;
        float div255 = 1 / 255.0f;

        for (int j = area.min.y; j < area.max.y; ++j)
        {
            RGBA[] wfb_scan = wfb.scanline(j);

            // clamp to existing lines
            int[5] line_index = void;
            for (int l = 0; l < 5; ++l)
                line_index[l] = gfm.math.clamp(j - 2 + l, 0, h - 1);

            RGBA[][5] depth_scan = void;
            for (int l = 0; l < 5; ++l)
                depth_scan[l] = _depthMap.levels[0].scanline(line_index[l]);


            for (int i = area.min.x; i < area.max.x; ++i)
            {
                // clamp to existing columns
                int[5] col_index = void;
                for (int k = 0; k < 5; ++k)
                    col_index[k] = gfm.math.clamp(i - 2 + k, 0, w - 1);

                // Get depth for a 5x5 patch
                ubyte[5][5] depthPatch = void;
                for (int l = 0; l < 5; ++l)
                {
                    for (int k = 0; k < 5; ++k)
                    {
                        ubyte depthSample = depth_scan.ptr[l].ptr[col_index[k]].r;
                        depthPatch.ptr[l].ptr[k] = depthSample;
                    }
                }

                // compute normal
                float sx = depthPatch[1][0] + depthPatch[1][1] + depthPatch[2][0] + depthPatch[2][1] + depthPatch[3][0] + depthPatch[3][1]
                    - ( depthPatch[1][3] + depthPatch[1][4] + depthPatch[2][3] + depthPatch[2][4] + depthPatch[3][3] + depthPatch[3][4] );

                float sy = depthPatch[3][1] + depthPatch[4][1] + depthPatch[3][2] + depthPatch[4][2] + depthPatch[3][3] + depthPatch[4][3]
                    - ( depthPatch[0][1] + depthPatch[1][1] + depthPatch[0][2] + depthPatch[1][2] + depthPatch[0][3] + depthPatch[1][3] );

                enum float sz = 130.0f; // this factor basically tweak normals to make the UI flatter or not

                vec3f normal = vec3f(sx, sy, sz).normalized;

                RGBA ibaseColor = _diffuseMap.levels[0][i, j];
                vec3f baseColor = vec3f(ibaseColor.r * div255, ibaseColor.g * div255, ibaseColor.b * div255);

                vec3f color = vec3f(0.0f);
                vec3f toEye = vec3f(cast(float)i / cast(float)w - 0.5f,
                                    cast(float)j / cast(float)h - 0.5f,
                                    1.0f).normalized;

                float shininess = depth_scan[2].ptr[i].g * div255;

                float occluded;

                // Add ambient component
                {
                    float px = i + 0.5f;
                    float py = j + 0.5f;

                    float avgDepthHere =
                      ( _depthMap.linearSampleRed(1, px, py)
                        + _depthMap.linearSampleRed(2, px, py)
                        + _depthMap.linearSampleRed(3, px, py)
                        + _depthMap.linearSampleRed(4, px, py) ) * 0.25f;

                    occluded = ctLinearStep!(-90.0f, 0.0f)(depthPatch[2][2] - avgDepthHere);

                    vec3f ambientComponent = vec3f(occluded * ambientLight) * baseColor;

                    color += ambientComponent;
                }

                // cast shadows, ie. enlight what isn't in shadows
                {
                    enum float fallOff = 0.78f;

                    int samples = 11;

                    static immutable float[11] weights =
                    [
                        1.0f,
                        fallOff,
                        fallOff ^^ 2,
                        fallOff ^^ 3,
                        fallOff ^^ 4,
                        fallOff ^^ 5,
                        fallOff ^^ 6,
                        fallOff ^^ 7,
                        fallOff ^^ 8,
                        fallOff ^^ 9,
                        fallOff ^^ 10
                    ];

                    enum float totalWeights = (1.0f - (fallOff ^^ 11)) / (1.0f - fallOff) - 1;
                    enum float invTotalWeights = 1 / totalWeights;

                    float lightPassed = 0.0f;

                    int depthHere = depthPatch[2][2];
                    for (int sample = 1; sample < samples; ++sample)
                    {
                        int x = i + sample;
                        if (x >= w)
                            x = w - 1;
                        int y = j - sample;
                        if (y < 0)
                            y = 0;
                        int z = depthHere + sample;
                        int diff = z - _depthMap.levels[0][x, y].r;
                        lightPassed += ctLinearStep!(-60.0f, 0.0f)(diff) * weights.ptr[sample];
                    }
                    color += baseColor * light1Color * (lightPassed * invTotalWeights);
                }

                // secundary light
                {

                    float diffuseFactor = dot(normal, light2Dir);

                    if (diffuseFactor > 0)
                        color += baseColor * light2Color * diffuseFactor;
                }

                // specular reflection
                if (shininess != 0)
                {
                    vec3f lightReflect = reflect(light2Dir, normal);
                    float specularFactor = dot(toEye, lightReflect);
                    if (specularFactor > 0)
                    {
                        specularFactor = specularFactor * specularFactor;
                        specularFactor = specularFactor * specularFactor;
                        color += baseColor * light2Color * (specularFactor * 4.0f * shininess);
                    }
                }

                // skybox reflection (use the same shininess as specular)
                if (shininess != 0)
                {
                    vec3f pureReflection = reflect(toEye, normal);

                    float skyx = 0.5f + ((0.5f + pureReflection.x *0.5f) * (skybox.width - 1));
                    float skyy = 0.5f + ((0.5f + pureReflection.y *0.5f) * (skybox.height - 1));

                    // 2nd order derivatives
                    float depthDX = depthPatch[3][1] + depthPatch[3][2] + depthPatch[3][3]
                        + depthPatch[1][1] + depthPatch[1][2] + depthPatch[1][3]
                        - 2 * (depthPatch[2][1] + depthPatch[2][2] + depthPatch[2][3]);

                    float depthDY = depthPatch[1][3] + depthPatch[2][3] + depthPatch[3][3]
                        + depthPatch[1][1] + depthPatch[2][1] + depthPatch[3][1]
                        - 2 * (depthPatch[1][2] + depthPatch[2][2] + depthPatch[3][2]);

                    float depthDerivSqr = depthDX * depthDX + depthDY * depthDY;
                    float indexDeriv = depthDerivSqr * skybox.width * skybox.height;

                    // cooking here
                    // log2 scaling + threshold
                    float mipLevel = 0.5f * fastlog2(1.0f + indexDeriv * 0.00001f);

                    vec4f skyColor = skybox.linearMipmapSample(mipLevel, skyx, skyy) * div255;
                    color += shininess * 0.3f * skyColor.rgb;
                }

                // Add light emitted by neighbours
                {
                    float ic = i + 0.5f;
                    float jc = j + 0.5f;

                    // Get alpha-premultiplied, avoids some white highlights
                    // Maybe we could solve the white highlights by having the whole mipmap premultiplied
                    vec4f colorLevel1 = _diffuseMap.linearSample!true(1, ic, jc);
                    vec4f colorLevel2 = _diffuseMap.linearSample!true(2, ic, jc);
                    vec4f colorLevel3 = _diffuseMap.linearSample!true(3, ic, jc);
                    vec4f colorLevel4 = _diffuseMap.linearSample!true(4, ic, jc);
                    vec4f colorLevel5 = _diffuseMap.linearSample!true(5, ic, jc);

                    vec3f emitted = colorLevel1.rgb * 0.2f;
                    emitted += colorLevel2.rgb * 0.3f;
                    emitted += colorLevel3.rgb * 0.25f;
                    emitted += colorLevel4.rgb * 0.15f;
                    emitted += colorLevel5.rgb * 0.10f;

                    emitted *= (div255 * 1.5f);

                    color += emitted;
                }

                // Show normals
                //color = vec3f(0.5f) + normal * 0.5f;

                // Show depth
                {
                    //float depthColor = depthPatch[2][2] / 255.0f;
                    //color = vec3f(depthColor);
                }

                // Show diffuse
                //color = baseColor;

                color.x = gfm.math.clamp(color.x, 0.0f, 1.0f);
                color.y = gfm.math.clamp(color.y, 0.0f, 1.0f);
                color.z = gfm.math.clamp(color.z, 0.0f, 1.0f);


                int r = cast(int)(0.5f + color.x * 255.0f);
                int g = cast(int)(0.5f + color.y * 255.0f);
                int b = cast(int)(0.5f + color.z * 255.0f);

                if (swapRB)
                {
                    int temp = r;
                    r = b;
                    b = temp;
                }

                // write composited color
                RGBA finalColor = RGBA(cast(ubyte)r, cast(ubyte)g, cast(ubyte)b, 255);

                wfb_scan.ptr[i] = finalColor;
            }
        }
    }
}

private:

// cause smoothStep wasn't needed
float ctLinearStep(float a, float b)(float t) pure nothrow @nogc
{
    if (t <= a)
        return 0.0f;
    else if (t >= b)
        return 1.0f;
    else
    {
        enum float divider = 1.0f / (b - a);
        return (t - a) * divider;
    }
}

// cause smoothStep wasn't needed
float linearStep(float a, float b, float t) pure nothrow @nogc
{
    if (t <= a)
        return 0.0f;
    else if (t >= b)
        return 1.0f;
    else
    {
        float divider = 1.0f / (b - a);
        return (t - a) * divider;
    }
}

// log2 approximation by Laurent de Soras
// http://www.flipcode.com/archives/Fast_log_Function.shtml
float fastlog2(float val)
{
    union fi_t
    {
        int i;
        float f;
    }

    fi_t fi;
    fi.f = val;
    int x = fi.i;
    int log_2 = ((x >> 23) & 255) - 128;
    x = x & ~(255 << 23);
    x += 127 << 23;
    fi.i = x;
    return fi.f + log_2;
}


/// Special look-up for depth-only lookup
float linearSampleRed(bool premultiplied = false)(ref Mipmap mipmap, int level, float x, float y)
{
    Image!RGBA* image = &mipmap.levels[level];

    static immutable float[14] factors = [ 1.0f, 0.5f, 0.25f, 0.125f,
    0.0625f, 0.03125f, 0.015625f, 0.0078125f,
    0.00390625f, 0.001953125f, 0.0009765625f, 0.00048828125f,
    0.000244140625f, 0.0001220703125f];

    float divider = factors[level];
    x = x * divider - 0.5f;
    y = y * divider - 0.5f;

    float maxX = image.w - 1.001f; // avoids an edge case with truncation
    float maxY = image.h - 1.001f;

    if (x < 0)
        x = 0;
    if (y < 0)
        y = 0;
    if (x > maxX)
        x = maxX;
    if (y > maxY)
        y = maxY;

    int ix = cast(int)x;
    int iy = cast(int)y;
    float fx = x - ix;

    int ixp1 = ix + 1;
    if (ixp1 >= image.w)
        ixp1 = image.w - 1;
    int iyp1 = iy + 1;
    if (iyp1 >= image.h)
        iyp1 = image.h - 1;

    float fxm1 = 1 - fx;
    float fy = y - iy;
    float fym1 = 1 - fy;

    RGBA[] L0 = image.scanline(iy);
    RGBA[] L1 = image.scanline(iyp1);

    float A = L0.ptr[ix].r;
    float B = L0.ptr[ixp1].r;
    float C = L1.ptr[ix].r;
    float D = L1.ptr[ixp1].r;

    float r = (A * fxm1 + B * fx) * fym1 + (C * fxm1 + D * fx) * fy;

    return r;
}


