package app.kaze.phone;

import android.Manifest;
import android.app.Activity;
import android.app.Application;
import android.content.pm.PackageManager;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CameraMetadata;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.opengl.GLES11Ext;
import android.opengl.GLES20;
import android.opengl.GLSurfaceView;
import android.opengl.Matrix;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.view.View;
import app.kaze.shared.Config;
import com.google.ar.core.*;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.platform.PlatformView;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import javax.microedition.khronos.egl.EGLConfig;
import javax.microedition.khronos.opengles.GL10;

/** Local camera tracking and metric geometry only. No images leave this view. */
public final class GuardianArView implements PlatformView, GLSurfaceView.Renderer, LocationListener,
        Application.ActivityLifecycleCallbacks {
    private final Activity activity;
    private final GLSurfaceView view;
    private final LocationManager locations;
    private final MethodChannel channel;
    private final Handler main = new Handler(Looper.getMainLooper());
    private Session session;
    private volatile Location fix;
    private volatile boolean stopped, started;
    private boolean tracked;
    private long lastFix, opened;
    private volatile long lease;
    private final Runnable watchdog = new Runnable() {
        @Override public void run() {
            if (!started || stopped) return;
            long now = SystemClock.elapsedRealtime();
            if ((lease == 0 && now - opened > 15000) || (lease > 0 && now - lease > 2500)) {
                fail(); return;
            }
            main.postDelayed(this, 500);
        }
    };
    private volatile List<Map<String, Object>> points = Collections.emptyList();
    private int width = 1, height = 1, texture, backgroundProgram, geometryProgram;
    private final float[] projection = new float[16], camera = new float[16], mvp = new float[16];
    private final FloatBuffer quad = buffer(new float[]{-1,-1, 1,-1, -1,1, 1,1});
    private final FloatBuffer uv = buffer(new float[8]);

    public GuardianArView(Activity activity, int id, BinaryMessenger messenger) {
        this.activity = activity;
        view = new GLSurfaceView(activity);
        view.setEGLContextClientVersion(2);
        view.setPreserveEGLContextOnPause(true);
        view.setRenderer(this);
        locations = activity.getSystemService(LocationManager.class);
        channel = new MethodChannel(messenger, "app.kaze/guardian-ar/" + id);
        channel.setMethodCallHandler((call, result) -> {
            switch (call.method) {
                case "start": start(); result.success(null); break;
                case "render":
                    if (started && !stopped && call.arguments instanceof List && ((List<?>)call.arguments).size() <= 200) {
                        @SuppressWarnings("unchecked") List<Map<String,Object>> next = (List<Map<String,Object>>)call.arguments;
                        view.queueEvent(() -> { points = next; lease = SystemClock.elapsedRealtime(); });
                    }
                    result.success(null); break;
                case "stop": stop(); result.success(null); break;
                default: result.notImplemented();
            }
        });
        activity.getApplication().registerActivityLifecycleCallbacks(this);
    }

    private void start() {
        if (started || stopped) return;
        // A platform view may never open a camera on an active wearer device.
        if (Config.prefs(activity).getBoolean("active", false) ||
            activity.checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED ||
            activity.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            fail(); return;
        }
        try {
            session = new Session(activity);
            Integer timebase = activity.getSystemService(CameraManager.class)
                .getCameraCharacteristics(session.getCameraConfig().getCameraId())
                .get(CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE);
            if (timebase == null || timebase != CameraMetadata.SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME) {
                throw new IllegalStateException("Camera and location clocks cannot be synchronized");
            }
            com.google.ar.core.Config config = new com.google.ar.core.Config(session);
            config.setPlaneFindingMode(com.google.ar.core.Config.PlaneFindingMode.DISABLED);
            config.setFocusMode(com.google.ar.core.Config.FocusMode.AUTO);
            session.configure(config);
            locations.requestLocationUpdates(LocationManager.GPS_PROVIDER, 0, 0, this, Looper.getMainLooper());
            session.resume(); opened = SystemClock.elapsedRealtime(); started = true; view.onResume();
            main.postDelayed(watchdog, 500);
        } catch (Exception e) { fail(); }
    }

    private void stop() {
        if (stopped) return;
        stopped = true; started = false; points = Collections.emptyList(); fix = null;
        main.removeCallbacks(watchdog);
        locations.removeUpdates(this);
        view.setVisibility(View.INVISIBLE);
        // Join the GL thread before pausing/closing the native session.
        view.onPause();
        if (session != null) { session.pause(); session.close(); session = null; }
    }
    private void fail() {
        points = Collections.emptyList();
        main.post(() -> { stop(); channel.invokeMethod("failure", null); });
    }
    @Override public View getView() { return view; }
    @Override public void dispose() {
        stop(); activity.getApplication().unregisterActivityLifecycleCallbacks(this);
        channel.setMethodCallHandler(null);
    }
    @Override public void onLocationChanged(Location location) { fix = new Location(location); }
    @Override public void onProviderDisabled(String provider) { fail(); }
    @Override public void onProviderEnabled(String provider) {}
    @Override public void onStatusChanged(String provider, int status, Bundle extras) {}

    @Override public void onSurfaceCreated(GL10 gl, EGLConfig config) {
        try {
            int[] ids = new int[1]; GLES20.glGenTextures(1, ids, 0); texture = ids[0];
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texture);
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR);
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR);
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE);
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE);
            backgroundProgram = program("attribute vec2 p; attribute vec2 uv; varying vec2 v; void main(){gl_Position=vec4(p,0.,1.);v=uv;}",
                "#extension GL_OES_EGL_image_external : require\nprecision mediump float; uniform samplerExternalOES image; varying vec2 v; void main(){gl_FragColor=texture2D(image,v);}");
            geometryProgram = program("attribute vec3 p; uniform mat4 mvp; void main(){gl_Position=mvp*vec4(p,1.);}",
                "precision mediump float; uniform vec4 color; void main(){gl_FragColor=color;}");
        } catch (RuntimeException e) { fail(); }
    }
    @Override public void onSurfaceChanged(GL10 gl, int width, int height) {
        this.width = width; this.height = height; GLES20.glViewport(0,0,width,height);
    }
    @Override public void onDrawFrame(GL10 gl) {
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT | GLES20.GL_DEPTH_BUFFER_BIT);
        if (!started || stopped || session == null) return;
        try {
            if (activity.checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED ||
                activity.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED ||
                Config.prefs(activity).getBoolean("active", false)) { fail(); return; }
            session.setDisplayGeometry(activity.getWindowManager().getDefaultDisplay().getRotation(), width, height);
            session.setCameraTextureName(texture);
            Frame frame = session.update();
            if (frame.getTimestamp() == 0) return;
            GLES20.glDisable(GLES20.GL_DEPTH_TEST);
            GLES20.glUseProgram(backgroundProgram);
            quad.position(0); uv.position(0);
            frame.transformCoordinates2d(Coordinates2d.OPENGL_NORMALIZED_DEVICE_COORDINATES, quad,
                Coordinates2d.TEXTURE_NORMALIZED, uv);
            attribute(backgroundProgram, "p", 2, quad); attribute(backgroundProgram, "uv", 2, uv);
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0);
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texture);
            GLES20.glUniform1i(GLES20.glGetUniformLocation(backgroundProgram, "image"), 0);
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP,0,4);
            Camera c = frame.getCamera();
            if ((lease == 0 && SystemClock.elapsedRealtime() - opened > 15000) ||
                (lease > 0 && SystemClock.elapsedRealtime() - lease > 2500)) { fail(); return; }
            if (c.getTrackingState() != TrackingState.TRACKING) { if (tracked) fail(); return; }
            tracked = true;
            sample(frame, c);
            c.getProjectionMatrix(projection,0,.1f,100f); c.getViewMatrix(camera,0);
            Matrix.multiplyMM(mvp,0,projection,0,camera,0);
            GLES20.glEnable(GLES20.GL_DEPTH_TEST);
            GLES20.glUseProgram(geometryProgram);
            GLES20.glUniformMatrix4fv(GLES20.glGetUniformLocation(geometryProgram,"mvp"),1,false,mvp,0);
            for (Map<String,Object> p : points) draw(p);
        } catch (Exception e) { fail(); }
    }

    private void sample(Frame frame, Camera camera) {
        Location p = fix;
        if (p == null || p.getElapsedRealtimeNanos() <= lastFix) return;
        double age = (frame.getTimestamp() - p.getElapsedRealtimeNanos()) / 1e6;
        if (age < 0 || age > 200) return;
        lastFix = p.getElapsedRealtimeNanos();
        Pose pose = camera.getPose();
        Map<String,Object> m = new HashMap<>();
        m.put("t",lastFix / 1e9); m.put("x",(double)pose.tx()); m.put("y",(double)pose.ty()); m.put("z",(double)pose.tz());
        m.put("latitude",p.getLatitude()); m.put("longitude",p.getLongitude());
        m.put("accuracy", p.hasAccuracy() ? (double)p.getAccuracy() : -1d);
        m.put("ageMs",age); m.put("mock",p.isFromMockProvider());
        if (p.hasAltitude() && p.hasVerticalAccuracy()) {
            m.put("altitude",p.getAltitude()); m.put("verticalAccuracy",(double)p.getVerticalAccuracyMeters());
            m.put("altitudeDatum","WGS84-ellipsoid");
        }
        main.post(() -> { if (!stopped) channel.invokeMethod("sample",m); });
    }

    private static float number(Map<String,Object> p, String key) {
        Object v = p.get(key); return v instanceof Number ? ((Number)v).floatValue() : Float.NaN;
    }
    private void draw(Map<String,Object> p) {
        float x = number(p,"x"), y = number(p,"y"), z = number(p,"z");
        float r = number(p,"uncertainty"), v = number(p,"verticalUncertainty");
        if (!Float.isFinite(x) || !Float.isFinite(y) || !Float.isFinite(z) || !(r > 0 && r <= 10 && v > 0 && v <= 10)) return;
        boolean watch = "watch".equals(p.get("source"));
        GLES20.glUniform4f(GLES20.glGetUniformLocation(geometryProgram,"color"),watch ? 1f : 0f, watch ? .55f : 1f, watch ? .05f : 1f,1f);
        float[] ring = new float[48 * 3];
        for (int i=0;i<48;i++) { ring[3*i]=x+r*(float)Math.cos(i*Math.PI/24); ring[3*i+1]=y; ring[3*i+2]=z+r*(float)Math.sin(i*Math.PI/24); }
        geometry(ring,GLES20.GL_LINE_LOOP);
        geometry(new float[]{x,y-v,z,x,y+v,z},GLES20.GL_LINES);
        // A small metric octahedron marks the observation; rings are allowances.
        float s=.18f;
        float[][] vertices={{x+s,y,z},{x,y,z+s},{x-s,y,z},{x,y,z-s}};
        float[] triangles=new float[8*9]; int k=0;
        for (int j=0;j<2;j++) for (int i=0;i<4;i++) {
            triangles[k++]=x;triangles[k++]=y+(j==0?s:-s);triangles[k++]=z;
            for(float f:vertices[i]) triangles[k++]=f;
            for(float f:vertices[(i+1)%4]) triangles[k++]=f;
        }
        geometry(triangles,GLES20.GL_TRIANGLES);
    }
    private void geometry(float[] vertices,int mode) {
        attribute(geometryProgram,"p",3,buffer(vertices)); GLES20.glDrawArrays(mode,0,vertices.length/3);
    }
    private static FloatBuffer buffer(float[] values) {
        FloatBuffer b=ByteBuffer.allocateDirect(values.length*4).order(ByteOrder.nativeOrder()).asFloatBuffer(); b.put(values).position(0); return b;
    }
    private static void attribute(int program,String name,int size,FloatBuffer values) {
        int a=GLES20.glGetAttribLocation(program,name); values.position(0);
        GLES20.glVertexAttribPointer(a,size,GLES20.GL_FLOAT,false,0,values); GLES20.glEnableVertexAttribArray(a);
    }
    private static int shader(int type,String source) {
        int s=GLES20.glCreateShader(type); GLES20.glShaderSource(s,source); GLES20.glCompileShader(s);
        int[] ok=new int[1];GLES20.glGetShaderiv(s,GLES20.GL_COMPILE_STATUS,ok,0);
        if(ok[0]==0)throw new IllegalStateException("AR shader compilation failed");return s;
    }
    private static int program(String vertex,String fragment) {
        int v=shader(GLES20.GL_VERTEX_SHADER,vertex), f=shader(GLES20.GL_FRAGMENT_SHADER,fragment);
        int p=GLES20.glCreateProgram();GLES20.glAttachShader(p,v);GLES20.glAttachShader(p,f);GLES20.glLinkProgram(p);
        GLES20.glDeleteShader(v);GLES20.glDeleteShader(f);
        int[] ok=new int[1];GLES20.glGetProgramiv(p,GLES20.GL_LINK_STATUS,ok,0);
        if(ok[0]==0)throw new IllegalStateException("AR shader linking failed");return p;
    }
    @Override public void onActivityPaused(Activity a) { if(a==activity) fail(); }
    @Override public void onActivityStopped(Activity a) { if(a==activity) stop(); }
    @Override public void onActivityDestroyed(Activity a) { if(a==activity) dispose(); }
    @Override public void onActivityCreated(Activity a,Bundle b) {}
    @Override public void onActivityStarted(Activity a) {}
    @Override public void onActivityResumed(Activity a) {}
    @Override public void onActivitySaveInstanceState(Activity a,Bundle b) {}
}
