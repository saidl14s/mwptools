/*
 * Copyright (C) 2014 Jonathan Hudson <jh+mwptools@daria.co.uk>
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 3
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
 */

using Gtk;
using Gdl;
using Clutter;
using Champlain;
using GtkChamplain;

extern double get_locale_double(string str);
extern int atexit(VoidFunc func);
extern string mwpvers;
extern int cf_pipe(int *fds);

[DBus (name = "org.freedesktop.NetworkManager")]
interface NetworkManager : GLib.Object {
    public signal void StateChanged (uint32 state);
    public abstract uint32 State {owned get;}
}

public enum NMSTATE {
        UNKNOWN=0, ASLEEP=1, CONNECTING=2, CONNECTED=3, DISCONNECTED=4,
        NM_STATE_ASLEEP           = 10,
        NM_STATE_DISCONNECTED     = 20,
        NM_STATE_DISCONNECTING    = 30,
        NM_STATE_CONNECTING       = 40,
        NM_STATE_CONNECTED_LOCAL  = 50,
        NM_STATE_CONNECTED_SITE   = 60,
        NM_STATE_CONNECTED_GLOBAL = 70
    }

public struct VersInfo
{
    uint8 mrtype;
    uint8 mvers;
    MWChooser.MWVAR fctype;
    string fc_var;
    string board;
    string fc_git;
    uint8 fc_api[2];
    uint8 fc_vers[3];
}

public struct TelemStats
{
    SerialStats s;
    ulong toc;
    int tot;
    ulong avg;
}

public struct BatteryLevels
{
    float cell;
    float limit;
    string colour;
    string audio;
    string label;
    bool reached;
    public BatteryLevels(float _cell, string? _colour, string? _audio, string? _label)
    {
        cell = _cell;
        limit = 0f;
        colour = _colour;
        audio = _audio;
        label = _label;
        reached = false;
    }
}

public struct MavPOSDef
{
    uint16 minval;
    uint16 maxval;
    Craft.Special ptype;
    uint8 chan;
    uint8 set;
}

public class PosFormat : GLib.Object
{
    public static string lat(double _lat, bool dms)
    {
        if(dms == false)
            return "%.6f".printf(_lat);
        else
            return position(_lat, "%02d:%02d:%04.1f%c", "NS");
    }

    public static string lon(double _lon, bool dms)
    {
        if(dms == false)
            return "%.6f".printf(_lon);
        else
            return position(_lon, "%03d:%02d:%04.1f%c", "EW");
    }

    public static string pos(double _lat, double _lon, bool dms)
    {
        if(dms == false)
            return "%.6f %.6f".printf(_lat,_lon);
        else
        {
            var slat = lat(_lat,dms);
            var slon = lon(_lon,dms);
            StringBuilder sb = new StringBuilder ();
            sb.append(slat);
            sb.append(" ");
            sb.append(slon);
            return sb.str;
        }
    }

    private static string position(double coord, string fmt, string ind)
    {
        var neg = (coord < 0.0);
        var ds = Math.fabs(coord);
        int d = (int)ds;
        var rem = (ds-d)*3600.0;
        int m = (int)rem/60;
        double s = rem - m*60;
        if ((int)s*10 == 600)
        {
            m+=1;
            s = 0;
        }
        if (m == 60)
        {
            m = 0;
            d+=1;
        }
        var q = (neg) ? ind.get_char(1) : ind.get_char(0);
        return fmt.printf((int)d,(int)m,s,q);
    }
}

public class MWPCursor : GLib.Object
{
    private static void set_cursor(Gtk.Widget widget, Gdk.CursorType? cursor_type)
    {
        Gdk.Window gdk_window = widget.get_window();
        if (cursor_type != null)
            gdk_window.set_cursor(new Gdk.Cursor.for_display(widget.get_display(),
                                                             cursor_type));
        else
            gdk_window.set_cursor(null);
    }

    public static void set_busy_cursor(Gtk.Widget widget)
    {
        set_cursor(widget, Gdk.CursorType.WATCH);
    }

    public static void set_normal_cursor(Gtk.Widget widget)
    {
        set_cursor(widget, null);
    }
}

class MwpDockHelper : Object
{
    private Gtk.Window wdw = null;
    public bool floating {get; private set; default=false;}
    public void transient(Gtk.Window w, bool above=false)
    {
        wdw.set_keep_above(above);
        wdw.set_transient_for (w);
    }

    public MwpDockHelper (Gdl.DockItem di, Gdl.Dock dock, string title, bool _floater = false)
    {
        floating = _floater;
        wdw = new Gtk.Window();
        wdw.title = title;
        wdw.resize(480,320);
        wdw.window_position = Gtk.WindowPosition.MOUSE;
        wdw.type_hint =  Gdk.WindowTypeHint.DIALOG;


        if(!di.iconified && floating)
        {
            di.dock_to (null, Gdl.DockPlacement.FLOATING, 0);
            di.get_parent().reparent(wdw);
            wdw.show_all();
        }

        wdw.delete_event.connect(() => {
                di.iconify_item();
                return true;
            });

        di.dock_drag_end.connect(() => {
                if(di.get_toplevel() == dock)
                {
                    floating = false;
                    wdw.hide();
                }
                else
                {
                    floating = true;
                    di.dock_to (null, Gdl.DockPlacement.FLOATING, 0);
                    di.get_parent().reparent(wdw);
                    wdw.show_all();
                }
            });
        di.hide.connect(() => {
                wdw.hide();
            });

        di.show.connect(() => {
                if(!di.iconified && floating)
                {
                    di.dock_to (null, Gdl.DockPlacement.FLOATING, 0);
                    di.get_parent().reparent(wdw);
                    wdw.show_all();
                }
            });
    }
}

public class MWPlanner : Gtk.Application {
    private const uint MAXVSAMPLE=12;

    public Builder builder;
    public Gtk.ApplicationWindow window;
    public  Champlain.View view;
    public MWPMarkers markers;
    private string last_file;
    private ListBox ls;
    private Gtk.SpinButton zoomer;
    private Gtk.SpinButton timadj;
    private double looptimer;
    private Gtk.Label poslabel;
    public Gtk.Label stslabel;
    private Gtk.Statusbar statusbar;
    private uint context_id;
    private Gtk.Label elapsedlab;
    private double lx;
    private double ly;
    private Gtk.MenuItem menuup;
    private Gtk.MenuItem menudown;
    private Gtk.MenuItem menureplay;
    private Gtk.MenuItem menurestore;
    private Gtk.MenuItem menustore;
    private Gtk.MenuItem menuloadlog;
    private Gtk.MenuItem menubblog;
    private Gtk.MenuItem menubbload;
    private Gtk.MenuItem menunav;
    private Gtk.MenuItem menuncfg;
    private Gtk.MenuItem menumwvar;
    private Gtk.MenuItem saved_menuitem;
    private Gtk.MenuItem reboot;
    private Gtk.MenuItem menucli;
    private string saved_menutext;

    public static MWPSettings conf;
    private MWSerial msp;
    private Gtk.Button conbutton;
    private Gtk.ComboBoxText dev_entry;
    private Gtk.Label verlab;
    private Gtk.Label fmodelab;
    private Gtk.Label validatelab;
    private Gtk.Spinner armed_spinner;
    private Gtk.Label typlab;
    private Gtk.Label gpslab;
    private Gtk.Label labelvbat;

    private int nsampl;
    private float[] vbsamples;

    private Gtk.Label sensor_sts[6];

    private uint32 capability;
    private uint cmdtid;
    private uint spktid;
    private uint upltid;
    private Craft craft;
    private bool follow = false;
    private bool prlabel = false;
    private bool centreon = false;
    private bool naze32 = false;
    private bool mission_eeprom = false;
    private GtkChamplain.Embed embed;
    private PrefsDialog prefs;
    private SwitchDialog swd;
    private SetPosDialog setpos;
    private Gtk.AboutDialog about;
    private BBoxDialog bb_runner;
    private NavStatus navstatus;
    private RadioStatus radstatus;
    private NavConfig navconf;
    private MapSourceDialog msview;
    private MapSeeder mseed;
    private TelemetryStats telemstatus;
    private GPSInfo gpsinfo;
    private ArtWin art_win;
    private FlightBox fbox;
    private WPMGR wpmgr;
    private MissionItem[] wp_resp;
    private string boxnames = null;
    private static string mission;
    private static string serial;
    private static bool autocon;
    private int autocount = 0;
    private static bool mkcon = false;
    private static bool ignore_sz = false;
    private static bool nopoll = false;
    private static bool rawlog = false;
    private static bool norotate = false; // workaround for Ubuntu & old champlain
    private static bool gps_trail = false;
    private static bool no_max = false;
    private static bool force_mag = false;
    private static bool force_nc = false;
    private static bool force4 = false;
    private static bool chome= false;
    private static string mwoptstr;
    private static string llstr=null;
    private static string layfile=null;

    private MWChooser.MWVAR mwvar=MWChooser.MWVAR.AUTO;
    private uint8 vwarn1;
    private int licol;
    public  DockItem[] dockitem;
    private Gtk.CheckButton audio_cb;
    private Gtk.CheckButton autocon_cb;
    private Gtk.CheckButton logb;
    private bool audio_on;
    private uint8 sflags = 0;
    private uint8 nsats = 0;
    private uint8 _nsats = 0;
    private uint8 larmed = 0;
    private bool wdw_state = false;
    private time_t armtime;
    private time_t duration;
    private time_t pausetm;

    private int gfcse = 0;
    private uint8 armed = 0;
    private uint8 dac = 0;
    private bool have_home = false;
    private bool gpsfix;

    private Thread<int> thr;
    private bool xlog;
    private bool xaudio;
    private int[] playfd;
    private ReplayThread robj;
    private int replayer = 0;
    private Pid child_pid;
    private MSP.Cmds[] requests = {};
    private int tcycle = 0;
    private bool dopoll = false;
    private bool xdopoll = false;
    private bool rxerr = false;

    private uint64 acycle;
    private uint64 anvals;
    private uint32 xbits = 0;
    private uint8 api_cnt;
    private uint8 icount = 0;
    private bool usemag = false;
    private int16 mhead;
    public static string exstr;

    private bool have_vers;
    private bool have_misc;
    private bool have_api;
    private bool have_status;
    private bool have_wp;
    private bool have_nc;
    private bool have_fcv;
    private bool have_fcvv;
    private bool vinit;
    private bool need_preview;
    private bool xfailsafe = false;

    private uint8 gpscnt = 0;
    private uint8 want_special = 0;
    private uint8 last_ltmf = 0;
    private uint8 mavc = 0;
    private uint16 mavsensors = 0;
    private MavPOSDef[] mavposdef;
    private bool force_mav = false;
    private bool have_mspradio = false;
    private uint16 sensor;
    private uint16 xsensor = 0;
    private uint8 profile = 0;
    private double clat = 0.0;
    private double clon = 0.0;

    private MwpDockHelper mwpdh;

        /* for jump protection */
    private double xlon = 0;
    private double xlat = 0;
    private uint32 button_time = 0;

    private bool use_gst = false;
    private bool inav = false;
    private bool sensor_alm = false;
    private uint8 xs_state = 0;

    private uint16  rhdop = 10000;
    private uint gpsintvl = 0;
    private bool telem = false;
    private uint8 wp_max = 0;

    private Clutter.Text clutext;

    private enum DEBUG_FLAGS
    {
        NONE=0,
        WP = 1
    }

    private enum SAT_FLAGS
    {
        NONE=0,
        NEEDED = 1,
        URGENT = 2,
        BEEP = 4
    }

    private enum Player
    {
        NONE = 0,
        MWP,
        BBOX
    }

    public struct Position
    {
        double lat;
        double lon;
        double alt;
    }

    private Position home_pos;
    private Position rth_pos;
    private Position ph_pos;
    private uint ph_mask=0;
    private uint arm_mask=0;
    private uint rth_mask=0;
    private uint angle_mask=0;
    private uint horz_mask=0;
    private uint wp_mask=0;

    private uint no_ofix = 0;

    private TelemStats telstats;
    private LayMan lman;

    public enum NAVCAPS
    {
        NONE=0,
        WAYPOINTS=1,
        NAVSTATUS=2,
        NAVCONFIG=4,
        INAV_MR=8,
        INAV_FW=16
    }

    private NAVCAPS navcap;

    private enum DOCKLETS
    {
        MISSION=0,
        GPS,
        NAVSTATUS,
        VOLTAGE,
        RADIO,
        TELEMETRY,
        ARTHOR,
        FBOX,
        NUMBER
    }

    private enum MS_Column {
        ID,
        NAME,
        N_COLUMNS
    }

    private enum WPDL {
        IDLE=0,
        VALIDATE = 1,
        REPLACE = 2,
        POLL = 4,
        REPLAY = 8,
        SAVE_EEPROM = 16,
        GETINFO = 32
    }

    private struct WPMGR
    {
        MSP_WP[] wps;
        WPDL wp_flag;
        uint8 npts;
        uint8 wpidx;
    }

    private enum WPFAIL {
        OK=0,
        NO = (1<<0),
        ACT = (1<<1),
        LAT = (1<<2),
        LON = (1<<3),
        ALT = (1<<4),
        P1 = (1<<5),
        P2 = (1<<6),
        P3 = (1<<7),
        FLAG = (1<<8)
    }

    private enum POSMODE
    {
        HOME = 1,
        PH = 2,
        RTH = 4,
        WP = 8
    }

    private string [] disarm_reason =
    {
        "None", "Timeout", "Sticks", "Switch_3d", "Switch",
            "Killswitch", "Failsafe", "Navigation" };

    private const string[] failnames = {"WPNO","ACT","LAT","LON","ALT","P1","P2","P3","FLAG"};

    private const uint TIMINTVL=50;
    private const uint ANIMINTVL=(300/TIMINTVL);
    private const uint BEATINTVL=(60000/TIMINTVL);
    private const uint DURAINTVL=((1000/TIMINTVL) - 1);
    private const uint STATINTVL=(800/TIMINTVL);
    private const uint NODATAINTVL=(5000/TIMINTVL);
    private const uint SATINTVL=(10000/TIMINTVL);
    private const uint USATINTVL=(2000/TIMINTVL);
    private const uint UUSATINTVL=(4000/TIMINTVL);
    private const uint RESTARTINTVL=(30000/TIMINTVL);
    private const uint MAVINTVL=(2000/TIMINTVL);
    private const uint CRITINTVL=(3000/TIMINTVL);

    private enum SATS
    {
        MINSATS = 6
    }

    private const double RAD2DEG = 57.29578;
    private const string RED_ALERT = "bleet.ogg";
    private const string ORANGE_ALERT = "orange.ogg";
    private const string GENERAL_ALERT = "beep-sound.ogg";
    private const string SAT_ALERT = "sat_alert.ogg";

    private static BatteryLevels [] vlevels = {
        BatteryLevels(3.7f, "#60ff00", null, null),
        BatteryLevels(3.57f, "#FFCE00", null, null),
        BatteryLevels(3.47f, "#FF5400", ORANGE_ALERT, null),
        BatteryLevels(3.0f,  "red", RED_ALERT, null),
        BatteryLevels(0.0f, null, null, "n/a")
    };

    private Timer lastp;
    private uint nticks = 0;
    private uint lastm;
    private uint lastrx;
    private uint last_ga = 0;
    private uint last_gps = 0;
    private uint last_crit = 0;
    private uint last_tm = 0;
    private uint lastok;
    private uint last_an = 0;
    private uint last_sv = 0;
    private static bool offline = false;
    private static string rfile = null;
    private static string bfile = null;
    private static int dmrtype=Craft.Vehicles.QUADX; // default to quad
    private static DEBUG_FLAGS debug_flags = 0;
    private static VersInfo vi ={0};
    private static bool set_fs;
    private static int stack_size = 0;
    public static unowned string ulang;
    private static bool ignore_3dr = false;

    private static string sndstr;
    private static string rrstr;
    private int nrings = 0;
    private double ringint = 0;
    private bool replay_paused;

    private const Gtk.TargetEntry[] targets = {
        {"text/uri-list",0,0}
    };

    const OptionEntry[] options = {
        { "mission", 'm', 0, OptionArg.STRING, out mission, "Mission file", null},
        { "serial-device", 's', 0, OptionArg.STRING, out serial, "Serial device", null},
        { "device", 'd', 0, OptionArg.STRING, out serial, "Serial device", null},
        { "flight-controller", 'f', 0, OptionArg.STRING, out mwoptstr, "mw|mwnav|bf|cf", null},
        { "connect", 'c', 0, OptionArg.NONE, out mkcon, "connect to first device", null},
        { "auto-connect", 'a', 0, OptionArg.NONE, out autocon, "auto-connect to first device", null},
        { "no-poll", 'N', 0, OptionArg.NONE, out nopoll, "don't poll for nav info", null},
        { "no-trail", 'T', 0, OptionArg.NONE, out gps_trail, "don't display GPS trail", null},
        { "raw-log", 'r', 0, OptionArg.NONE, out rawlog, "log raw serial data to file", null},
        { "ignore-sizing", 0, 0, OptionArg.NONE, out ignore_sz, "ignore minimum size constraint", null},
        { "full-screen", 0, 0, OptionArg.NONE, out set_fs, "open full screen", null},
        { "ignore-rotation", 0, 0, OptionArg.NONE, out norotate, "ignore vehicle icon rotation on old libchamplain", null},
        { "dont-maximise", 0, 0, OptionArg.NONE, out no_max, "don't maximise the window", null},
        { "force-mag", 0, 0, OptionArg.NONE, out force_mag, "force mag for vehicle direction", null},
        { "force-nav", 0, 0, OptionArg.NONE, out force_nc, "force nav capaable", null},
        { "layout", 'l', 0, OptionArg.STRING, out layfile, "Layout name", null},
        { "force-type", 't', 0, OptionArg.INT, out dmrtype, "Model type", null},
        { "force4", '4', 0, OptionArg.NONE, out force4, "Force ipv4", null},
        { "ignore-3dr", '3', 0, OptionArg.NONE, out ignore_3dr, "Ignore 3DR RSSI info", null},
        { "centre-on-home", 'H', 0, OptionArg.NONE, out chome, "Centre on home", null},
        { "debug-flags", 0, 0, OptionArg.INT, out debug_flags, "Debug flags (mask)", null},
        { "replay-mwp", 'p', 0, OptionArg.STRING, out rfile, "replay mwp log file", null},
        { "replay-bbox", 'b', 0, OptionArg.STRING, out bfile, "replay bbox log file", null},
        { "centre", 0, 0, OptionArg.STRING, out llstr, "Centre position", null},
        { "offline", 0, 0, OptionArg.NONE, out offline, "force offline proxy mode", null},
        { "n-points", 'S', 0, OptionArg.INT, out stack_size, "Number of points shown in GPS trail", "INT"},
        { "rings", 0, 0, OptionArg.STRING, out rrstr, "Range rings (number, interval(m)), e.g. --rings 10,20", null},
        { "sound-daemon", 0, 0, OptionArg.STRING, out sndstr, "sound daemon", null},
        {null}
    };

    void show_dock_id (DOCKLETS id, bool iconify=false)
    {
        if(dockitem[id].is_closed() && !dockitem[id].is_iconified())
        {
            dockitem[id].show();
            if(iconify)
                dockitem[id].iconify_item();
        }
    }

    bool item_visible(DOCKLETS id)
    {
        return !dockitem[id].is_closed();
    }

    MWPlanner ()
    {
        Object(application_id: "mwp.application", flags: ApplicationFlags.FLAGS_NONE);
    }

    public void cleanup()
    {
        if(conf.atexit != null)
            try {
                Process.spawn_command_line_sync (conf.atexit);
            } catch {}
    }


    private void handle_replay_pause()
    {
        int signum;
        if(replay_paused)
        {
            signum = Posix.SIGCONT;
            time_t now;
            time_t (out now);
            armtime += (now - pausetm);
        }
        else
        {
            time_t (out pausetm);
            signum = Posix.SIGSTOP;
        }
        replay_paused = !replay_paused;
        if(replayer == Player.BBOX)
        {
            Posix.kill(child_pid, signum);
        }
        else
        {
            if(thr != null)
                robj.pause(replay_paused);
        }
    }

    public override void activate ()
    {

        base.startup();
        wpmgr = WPMGR();
        mwvar = MWChooser.fc_from_arg0();
        vbsamples = new float[MAXVSAMPLE];

        conf = new MWPSettings();
        conf.read_settings();

        ulang = Intl.setlocale(LocaleCategory.NUMERIC, "");

        if(conf.uilang == "en")
            Intl.setlocale(LocaleCategory.NUMERIC, "C");

        builder = new Builder ();

        if(layfile == null && conf.deflayout != null)
            layfile = conf.deflayout;

        if(conf.fctype != null)
            mwvar = MWChooser.fc_from_name(conf.fctype);

        var confdir = GLib.Path.build_filename(Environment.get_user_config_dir(),"mwp");
        try
        {
            var dir = File.new_for_path(confdir);
            dir.make_directory_with_parents ();
        } catch {};

        gpsintvl = conf.gpsintvl / TIMINTVL;

        if(conf.mediap.length == 0)
            use_gst = true;

        if(sndstr != null && sndstr.length < 2)
            sndstr = null;

        if(rrstr != null)
        {
            var parts = rrstr .split(",");
            if(parts.length == 2)
            {
                nrings = int.parse(parts[0]);
                ringint = double.parse(parts[1]);
            }
        }

        var fn = MWPUtils.find_conf_file("mwp.ui");
        if (fn == null)
        {
            MWPLog.message ("No UI definition file\n");
            quit();
        }
        else
        {
            try
            {
                builder.add_from_file (fn);
            } catch (Error e) {
                MWPLog.message ("Builder: %s\n", e.message);
                quit();
            }
        }

        var cvers = Champlain.VERSION_S;
        if (cvers == "0.12.11")
        {
            MWPLog.message("libchamplain 0.12.11 may not draw maps at scale > 16\n");
            MWPLog.message("Consider downgrading, upgrading or building from source\n");
        }
        else
            MWPLog.message("libchamplain %s\n", Champlain.VERSION_S);

        gps_trail = !gps_trail; // yet more jh logic


        if(conf.ignore_nm == false)
        {
            if(offline == false)
            {
                try {
                    NetworkManager nm = Bus.get_proxy_sync (BusType.SYSTEM,
                                                            "org.freedesktop.NetworkManager",
                                                            "/org/freedesktop/NetworkManager");
                    NMSTATE istate = (NMSTATE)nm.State;
                    if(!(istate != NMSTATE.NM_STATE_CONNECTED_GLOBAL ||
                         istate != NMSTATE.UNKNOWN))
                    {
                        offline = true;
                        MWPLog.message("Forcing proxy offline [%s]\n",
                                       istate.to_string());
                    }
                } catch {}
            }
        }


        if(mwoptstr != null)
        {
            mwvar = MWChooser.fc_from_name(mwoptstr);
        }

        if(conf.atstart != null)
        {
            try {
                Process.spawn_command_line_async(conf.atstart);
            } catch {};
        }

        MapSource [] msources = {};
        if(conf.map_sources != null)
        {
            var msfn = MWPUtils.find_conf_file(conf.map_sources);
            if (msfn != null)
            {
                msources =   JsonMapDef.read_json_sources(msfn);
                if(JsonMapDef.port != 0)
                    JsonMapDef.run_proxy(conf.quaduri, offline);
            }
        }

        builder.connect_signals (null);
        window = builder.get_object ("window1") as Gtk.ApplicationWindow;
        this.add_window (window);
        window.set_application (this);
        window.window_state_event.connect( (e) => {
                wdw_state = ((e.new_window_state & Gdk.WindowState.FULLSCREEN) != 0);
            return false;
        });

        string icon=null;
        try {
            icon = MWPUtils.find_conf_file("mwp_icon.svg");
            window.set_icon_from_file(icon);
        } catch {};

        sensor_sts[0] = builder.get_object ("gyro_sts") as Gtk.Label;
        sensor_sts[1] = builder.get_object ("acc_sts") as Gtk.Label;
        sensor_sts[2] = builder.get_object ("baro_sts") as Gtk.Label;
        sensor_sts[3] = builder.get_object ("mag_sts") as Gtk.Label;
        sensor_sts[4] = builder.get_object ("gps_sts") as Gtk.Label;
        sensor_sts[5] = builder.get_object ("sonar_sts") as Gtk.Label;

        zoomer = builder.get_object ("spinbutton1") as Gtk.SpinButton;

        timadj = builder.get_object ("spinbutton2") as Gtk.SpinButton;
        timadj.adjustment.value = looptimer = conf.updint;

        timadj.value_changed.connect (() => {
                looptimer = timadj.adjustment.value;
            });

        var menuop = builder.get_object ("file_open") as Gtk.MenuItem;
        menuop.activate.connect (() => {
                on_file_open();
            });

        menuop = builder.get_object ("menu_save") as Gtk.MenuItem;
        menuop.activate.connect (() => {
                on_file_save();
            });

        menuop = builder.get_object ("menu_save_as") as Gtk.MenuItem;
        menuop.activate.connect (() => {
                on_file_save_as();
            });

        menuop = builder.get_object ("menu_prefs") as Gtk.MenuItem;
        menuop.activate.connect(() =>
            {
                var id = prefs.run_prefs(ref conf);
                if(id == 1001)
                {
                    build_deventry();
                    if(conf.speakint == 0)
                        conf.speakint = 15;
                    audio_cb.sensitive = true;
                }
            });

        setpos = new SetPosDialog(builder);
        menuop = builder.get_object ("menugoto") as Gtk.MenuItem;
        menuop.activate.connect(() =>
            {
                double glat, glon;
                if(setpos.get_position(out glat, out glon) == true)
                {
                    view.center_on(glat, glon);
                }
            });

        menuop = builder.get_object ("menu_set_def_pos") as Gtk.MenuItem;
        menuop.activate.connect(() =>
            {
                conf.latitude = view.get_center_latitude();
                conf.longitude = view.get_center_longitude();
                conf.zoom = view.get_zoom_level();
                conf.save_settings();
            });

        menuop = builder.get_object ("menu_recentre_mission") as Gtk.MenuItem;
        menuop.activate.connect(() =>
            {
                centre_mission(ls.to_mission(), true);
            });


        menucli = builder.get_object ("cliterm") as Gtk.MenuItem;
        menucli.activate.connect(() => {
                if(msp.available && armed == 0)
                {
                    remove_tid(ref cmdtid);
                    dopoll = false;
                    CLITerm t = new CLITerm(window);
                    t.configure_serial(msp);
                    t.show_all ();
                    t.on_exit.connect(() => {
                            serial_doom(conbutton);
                            Timeout.add_seconds(2, () => {
                                    connect_serial();
                                    return !msp.available;
                                });
                        });
                }
            });

        reboot = builder.get_object ("_reboot_") as Gtk.MenuItem;
        reboot.activate.connect(() =>
            {
                if(msp.available && armed == 0)
                {
                    send_cmd(MSP.Cmds.REBOOT,null, 0);
                }
            });

        reboot_status();
        msview = new MapSourceDialog(builder, window);
        menuop =  builder.get_object ("menu_maps") as Gtk.MenuItem;
        menuop.activate.connect(() => {
                var map_source_factory = Champlain.MapSourceFactory.dup_default();
                var sources =  map_source_factory.get_registered();
                foreach (Champlain.MapSourceDesc sr in sources)
                {
                    if(view.map_source.get_id() == sr.get_id())
                    {
                        msview.show_source(
                            sr.get_name(),
                            sr.get_id(),
                            sr.get_uri_format (),
                            sr.get_min_zoom_level(),
                            sr.get_max_zoom_level());
                        break;
                    }
                }
            });

        window.destroy.connect(() => {
                cleanup();
                remove_window(window);
                this.quit();
            });

        mseed = new MapSeeder(builder);
        menuop =  builder.get_object ("menu_seed") as Gtk.MenuItem;
        menuop.activate.connect(() => {
                mseed.run_seeder(view.map_source.get_id(),(int)zoomer.adjustment.value,
                                 view.get_bounding_box());

            });

        menuop = builder.get_object ("menu_quit") as Gtk.MenuItem;
        menuop.activate.connect (() => {
                conf.save_floating (mwpdh.floating);
                lman.save_config();
                remove_window(window);
            });

        menuop= builder.get_object ("menu_about") as Gtk.MenuItem;
        menuop.activate.connect (() => {
                about.show_all();
                about.run();
                about.hide();
            });

        menuup = builder.get_object ("upload_mission") as Gtk.MenuItem;
        menuup.sensitive = false;
        menuup.activate.connect (() => {
                upload_mission(WPDL.VALIDATE);
            });

        menudown = builder.get_object ("download_mission") as Gtk.MenuItem;
        menudown.sensitive =false;
        menudown.activate.connect (() => {
                download_mission();
            });

        menurestore = builder.get_object ("menu_restore_eeprom") as Gtk.MenuItem;
        menurestore.sensitive = false;
        menurestore.activate.connect (() => {
                uint8 zb=0;
                send_cmd(MSP.Cmds.WP_MISSION_LOAD, &zb, 1);
            });

        menustore = builder.get_object ("menu_store_eeprom") as Gtk.MenuItem;
        menustore.sensitive =false;
        menustore.activate.connect (() => {
                upload_mission(WPDL.SAVE_EEPROM);
            });


        menureplay = builder.get_object ("replay_log") as Gtk.MenuItem;
        menureplay.activate.connect (() => {
                replay_log(true);
            });

        menuloadlog = builder.get_object ("load_log") as Gtk.MenuItem;
        menuloadlog.activate.connect (() => {
                replay_log(false);
            });

        bb_runner = new BBoxDialog(builder, dmrtype, window, conf.logpath);
        menubblog = builder.get_object ("bb_menu_act") as Gtk.MenuItem;
        menubblog.activate.connect (() => {
                replay_bbox(true);
            });

        menubbload = builder.get_object ("bb_load_log") as Gtk.MenuItem;
        menubbload.activate.connect (() => {
                replay_bbox(false);
            });

        var sty = window.get_style_context();
        var acol = sty.get_background_color(Gtk.StateFlags.NORMAL);
        var colstr = "#%02x%02x%02x".printf((uint)(acol.red*255),
                                            (uint)(acol.green*255),
                                            (uint)(acol.blue*255));
        vlevels[4].colour = colstr;
        var cols = new string[5];
        for(var j = 0; j < 5; j++)
            cols[j] = vlevels[j].colour;

        navstatus = new NavStatus(builder, cols);

        menunav = builder.get_object ("nav_status_menu") as Gtk.MenuItem;
        menunav.activate.connect (() => {
                show_dock_id(DOCKLETS.NAVSTATUS,true);
            });

        menuncfg = builder.get_object ("nav_config_menu") as Gtk.MenuItem;
        menuncfg.sensitive =false;
        navconf = new NavConfig(window, builder);
        menuncfg.activate.connect (() => {
                navconf.show();
            });
        art_win = new ArtWin(acol);
        menuop = builder.get_object ("menu_art_hor") as Gtk.MenuItem;
        menuop.activate.connect (() => {
                show_dock_id(DOCKLETS.ARTHOR, true);
            });

        var mi = builder.get_object ("gps_menu_view") as Gtk.MenuItem;
        mi.activate.connect (() => {
                show_dock_id(DOCKLETS.GPS, true);
            });

        mi = builder.get_object ("tote_menu_view") as Gtk.MenuItem;
        mi.activate.connect (() => {
                show_dock_id(DOCKLETS.MISSION, false);
            });

        mi = builder.get_object ("voltage_menu_view") as Gtk.MenuItem;
        mi.activate.connect (() => {
                show_dock_id(DOCKLETS.VOLTAGE, true);
            });

        radstatus = new RadioStatus(builder);

        mi = builder.get_object ("radio_menu_view") as Gtk.MenuItem;
        mi.activate.connect (() => {
                show_dock_id(DOCKLETS.RADIO, true);
            });

        mi =  builder.get_object ("fbox_view") as Gtk.MenuItem;
        if(mi != null)
        {
            fbox  = new FlightBox(builder,window);
            mi.activate.connect(() => {
                    show_dock_id(DOCKLETS.FBOX, true);
                });
        }
        telemstatus = new TelemetryStats(builder);
        mi =  builder.get_object ("ss_dialog") as Gtk.MenuItem;
        mi.activate.connect(() => {
                show_dock_id(DOCKLETS.TELEMETRY, true);
            });

        mi =  builder.get_object ("lm_save") as Gtk.MenuItem;
        mi.activate.connect(() => {
                lman.save();
            });
        mi =  builder.get_object ("lm_restore") as Gtk.MenuItem;
        mi.activate.connect(() => {
                lman.restore();
            });

        embed = new GtkChamplain.Embed();
        view = embed.get_view();
        view.set_reactive(true);

        view.animation_completed.connect(() => {
                if(need_preview)
                {
                    need_preview = false;
                    Timeout.add_seconds(3, () => {
                    get_mission_pix();
                    return false;
                        });
                }
            });

        zoomer.adjustment.value_changed.connect (() =>
            {
                int  zval = (int)zoomer.adjustment.value;
                var val = view.get_zoom_level();
                if (val != zval)
                {
                    view.set_property("zoom-level", zval);
                }
            });

        var ent = builder.get_object ("entry1") as Gtk.Entry;
        var al = Units.distance((double)conf.altitude);
        ent.set_text("%.0f".printf(al));

        conf.settings_update.connect ((s) => {
                if( s == "display-distance" || s == "default-altitude")
                {
                    al = Units.distance((double)conf.altitude);
                    ent.set_text("%.0f".printf(al));
                }
                if (s == "display-dms" ||
                    s == "default-latitude" ||
                    s == "default-longitide")
                    anim_cb(true);


                if(s == "display-dms" ||
                    s == "display-distance" ||
                    s == "display-speed")
                {
                    fbox.update(item_visible(DOCKLETS.FBOX));
                }
            });

        var ent1 = builder.get_object ("entry2") as Gtk.Entry;
        ent1.set_text(conf.loiter.to_string());

        var scale = new Champlain.Scale();
        scale.connect_view(view);
        view.add_child(scale);
        var lm = view.get_layout_manager();
        lm.child_set(view,scale,"x-align", Clutter.ActorAlign.START);
        lm.child_set(view,scale,"y-align", Clutter.ActorAlign.END);
        view.set_keep_center_on_resize(true);
        add_source_combo(conf.defmap,msources);
        map_init_warning();

        var ag = new Gtk.AccelGroup();
        ag.connect('c', Gdk.ModifierType.CONTROL_MASK, 0, (a,o,k,m) => {
                if(craft != null)
                {
                    markers.remove_rings(view);
                    craft.init_trail();
                }
                return true;
            });

        ag.connect('+', Gdk.ModifierType.CONTROL_MASK, 0, (a,o,k,m) => {
                var val = view.get_zoom_level();
                var mmax = view.get_max_zoom_level();
                if (val != mmax)
                    view.set_property("zoom-level", val+1);
                return true;
            });

        ag.connect('-', Gdk.ModifierType.CONTROL_MASK, 0, (a,o,k,m) => {
                var val = view.get_zoom_level();
                var mmin = view.get_min_zoom_level();
                if (val != mmin)
                    view.set_property("zoom-level", val-1);
                return true;
            });

        ag.connect('f', Gdk.ModifierType.CONTROL_MASK, 0, (a,o,k,m) => {
                toggle_full_screen();
                return true;
            });

        ag.connect(Gdk.Key.F11, 0, 0, (a,o,k,m) => {
                toggle_full_screen();
                return true;
            });

        ag.connect('s', Gdk.ModifierType.CONTROL_MASK, 0, (a,o,k,m) => {
                show_serial_stats();
                return true;
            });


        ag.connect('i', Gdk.ModifierType.CONTROL_MASK, 0, (a,o,k,m) => {
                map_hide_warning();
                init_sstats();
                armed = 0;
                rhdop = 10000;
                init_have_home();
                armed_spinner.stop();
                armed_spinner.hide();
                if (conf.audioarmed == true)
                    audio_cb.active = false;
                if(conf.logarmed == true)
                    logb.active=false;
                gpsinfo.annul();
                navstatus.annul();
                fbox.annul();
                art_win.update(0, 0, item_visible(DOCKLETS.ARTHOR));
                set_bat_stat(0);
                duration = -1;
                if(craft != null)
                {
                    craft.remove_marker();
                }
                set_error_status(null);
                xsensor = 0;
                clear_sensor_array();
                labelvbat.set_text("");
                return true;
            });

        ag.connect('t', Gdk.ModifierType.CONTROL_MASK, 0, (a,o,k,m) => {
                armtime = 0;
                duration = 0;
                return true;
            });

        ag.connect('c', Gdk.ModifierType.CONTROL_MASK|Gdk.ModifierType.SHIFT_MASK,
                   0, (a,o,k,m) => {
                       connect_serial();
                       return true;
                   });

        ag.connect('v', Gdk.ModifierType.CONTROL_MASK, 0, (a,o,k,m) => {
                get_mission_pix();
                return true;
            });

        ag.connect('z', Gdk.ModifierType.CONTROL_MASK, 0, (a,o,k,m) => {
                ls.clear_mission();
                return true;
            });

        ag.connect(' ', 0, 0, (a,o,k,m) => {
                if(replayer != Player.NONE)
                {
                    handle_replay_pause();
                    return true;
                }
                else return false;
            });

        window.add_accel_group(ag);

        ls = new ListBox();
        ls.create_view(this);

        var scroll = new Gtk.ScrolledWindow (null, null);
        scroll.set_policy (Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC);
        scroll.set_min_content_width(400);
        scroll.add (ls.view);

        var grid =  builder.get_object ("grid1") as Gtk.Grid;
        gpsinfo = new GPSInfo(grid);

        var dock = new Dock ();
        var dockbar = new DockBar (dock);
        dockbar.set_style (DockBarStyle.ICONS);
        lman = new LayMan(dock, confdir,layfile,DOCKLETS.NUMBER);

        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL,2);

        box.pack_start (dockbar, false, false, 0);
        box.pack_end (dock, true, true, 0);

        var pane = builder.get_object ("paned1") as Gtk.Paned;

        dockitem = new DockItem[DOCKLETS.NUMBER];

        dockitem[DOCKLETS.GPS]= new DockItem.with_stock ("GPS",
                                                         "GPS Info", "gtk-refresh",
                                                         DockItemBehavior.NORMAL);

        dockitem[DOCKLETS.NAVSTATUS]= new DockItem.with_stock ("Status",
                         "NAV Status", "gtk-info",
                         DockItemBehavior.NORMAL);

        dockitem[DOCKLETS.ARTHOR]= new DockItem.with_stock ("Horizons",
                         "Artificial Horizon", "gtk-justify-fill",
                         DockItemBehavior.NORMAL);

        dockitem[DOCKLETS.VOLTAGE]= new DockItem.with_stock ("Volts",
                         "Battery Monitor", "gtk-dialog-warning",
                         DockItemBehavior.NORMAL);

        dockitem[DOCKLETS.RADIO]= new DockItem.with_stock ("Radio",
                         "Radio Status", "gtk-network",
                         DockItemBehavior.NORMAL );
        dock.add_item (dockitem[DOCKLETS.RADIO], DockPlacement.BOTTOM);

        dockitem[DOCKLETS.TELEMETRY]= new DockItem.with_stock ("Telemetry",
                         "Telemetry", "gtk-disconnect",
                         DockItemBehavior.NORMAL);

        dockitem[DOCKLETS.FBOX]= new DockItem.with_stock ("FlightView",
                         "FlightView", "gtk-find",
                         DockItemBehavior.NORMAL);

        dockitem[DOCKLETS.MISSION]= new DockItem.with_stock ("Mission",
                         "Mission Tote", "gtk-properties",
                         DockItemBehavior.NORMAL);

        dockitem[DOCKLETS.VOLTAGE].add (navstatus.voltbox);
        dockitem[DOCKLETS.MISSION].add (scroll);
        dockitem[DOCKLETS.GPS].add (grid);
        dockitem[DOCKLETS.NAVSTATUS].add (navstatus.grid);
        dockitem[DOCKLETS.RADIO].add (radstatus.box);
        dockitem[DOCKLETS.TELEMETRY].add (telemstatus.grid);
        dockitem[DOCKLETS.FBOX].add (fbox.vbox);
        dockitem[DOCKLETS.ARTHOR].add (art_win.box);

        dock.add_item (dockitem[DOCKLETS.ARTHOR], DockPlacement.BOTTOM);
        dock.add_item (dockitem[DOCKLETS.GPS], DockPlacement.BOTTOM);
        dock.add_item (dockitem[DOCKLETS.NAVSTATUS], DockPlacement.BOTTOM);
        dock.add_item (dockitem[DOCKLETS.VOLTAGE], DockPlacement.BOTTOM);
        dock.add_item (dockitem[DOCKLETS.TELEMETRY], DockPlacement.BOTTOM);
        dock.add_item (dockitem[DOCKLETS.RADIO], DockPlacement.BOTTOM);
        dock.add_item (dockitem[DOCKLETS.FBOX], DockPlacement.BOTTOM);
        dock.add_item (dockitem[DOCKLETS.MISSION], DockPlacement.TOP);

        view.notify["zoom-level"].connect(() => {
                var val = view.get_zoom_level();
                var zval = (int)zoomer.adjustment.value;
                if (val != zval)
                    zoomer.adjustment.value = (int)val;
            });

        markers = new MWPMarkers(ls);
        view.add_layer (markers.path);
        view.add_layer (markers.hpath);
        view.add_layer (markers.markers);
/*
  Sample for range rings. Note that 1st is below second)
  So the following sets the markers *below* the paths, which is NOT wanted
  var pp  =  markers.path.get_parent();
  pp.set_child_below_sibling(markers.markers, markers.hpath);
  pp.set_child_below_sibling(markers.markers, markers.path);
*/
        poslabel = builder.get_object ("poslabel") as Gtk.Label;
        stslabel = builder.get_object ("missionlab") as Gtk.Label;
        statusbar = builder.get_object ("statusbar1") as Gtk.Statusbar;
        context_id = statusbar.get_context_id ("Starting");
        elapsedlab =  builder.get_object ("elapsedlab") as Gtk.Label;
        logb = builder.get_object ("logger_cb") as Gtk.CheckButton;
        logb.toggled.connect (() => {
                if (logb.active)
                    Logger.start(last_file,vi,capability,profile,boxnames);
                else
                    Logger.stop();
            });

        autocon_cb = builder.get_object ("autocon_cb") as Gtk.CheckButton;

        audio_cb = builder.get_object ("audio_cb") as Gtk.CheckButton;
        audio_cb.sensitive = true; //(conf.speakint > 0);
        audio_cb.toggled.connect (() => {
                audio_on = audio_cb.active;
                if (audio_on)
                    start_audio();
                else
                    stop_audio();
            });
        var centreonb = builder.get_object ("checkbutton1") as Gtk.CheckButton;
        centreonb.toggled.connect (() => {
                centreon = centreonb.active;
            });


        var followb = builder.get_object ("checkbutton2") as Gtk.CheckButton;
        if(conf.autofollow)
        {
            follow = true;
            followb.active = true;
        }

        followb.toggled.connect (() => {
                follow = followb.active;
                if (follow == false && craft != null)
                {
                    craft.park();
                }
            });

        var mwc = new MWChooser(builder);

        menumwvar = builder.get_object ("menuitemmwvar") as Gtk.MenuItem;
        menumwvar.activate.connect (() => {
                var _m = mwc.get_version(mwvar);
                if(_m !=  MWChooser.MWVAR.UNDEF)
                    mwvar = _m;
            });

        prefs = new PrefsDialog(builder, window);
        swd = new SwitchDialog(builder, window);

        about = builder.get_object ("aboutdialog1") as Gtk.AboutDialog;
        about.version = mwpvers;
        about.copyright = "© 2014-%d Jonathan Hudson".printf(
            new DateTime.now_local().get_year());

        Gdk.Pixbuf pix = null;
        try  {
            pix = new Gdk.Pixbuf.from_file_at_size (icon, 200,200);
        } catch  {};
        about.logo = pix;

        if (mission == null)
        {
            if(llstr != null)
            {
                string[] delims =  {","," "};
                foreach (var delim in delims)
                {
                    var parts = llstr.split(delim);
                    if(parts.length == 2)
                    {
                        clat = InputParser.get_latitude(parts[0]);
                        clon = InputParser.get_longitude(parts[1]);
                        break;
                    }
                }
            }
            if(clat == 0.0 && clon == 0.0)
            {
                clat= conf.latitude;
                clon = conf.longitude;
            }
            view.center_on(clat,clon);
            anim_cb();
            view.set_property("zoom-level", conf.zoom);
            zoomer.adjustment.value = conf.zoom;
        }
        else
        {
            load_file(mission);
        }

        build_deventry();
        var te = dev_entry.get_child() as Gtk.Entry;
        te.can_focus = true;
        dev_entry.active = 0;
        conbutton = builder.get_object ("button1") as Gtk.Button;
        te.activate.connect(() => {
                if(!msp.available)
                    connect_serial();
            });

        verlab = builder.get_object ("verlab") as Gtk.Label;
        fmodelab = builder.get_object ("fmode") as Gtk.Label;
        validatelab = builder.get_object ("validated") as Gtk.Label;
        armed_spinner = builder.get_object ("armed_spinner") as Gtk.Spinner;
        typlab = builder.get_object ("typlab") as Gtk.Label;
        gpslab = builder.get_object ("gpslab") as Gtk.Label;
        labelvbat = builder.get_object ("labelvbat") as Gtk.Label;
        conbutton.clicked.connect(() => { connect_serial(); });

        msp = new MWSerial();
        msp.force4 = force4;
        msp.serial_lost.connect(() => { serial_doom(conbutton); });

        msp.serial_event.connect((s,cmd,raw,len,errs) => {
                handle_serial(cmd,raw,len,errs);
            });

        if(serial != null)
        {
            dev_entry.prepend_text(serial);
            dev_entry.active = 0;
        }

        autocon_cb.toggled.connect(() => {
                autocon =  autocon_cb.active;
                autocount = 0;
            });

        if(conf.vlevels != null)
        {
            string [] parts;
            parts = conf.vlevels.split(";");
            var i = 0;
            foreach (unowned string str in parts)
            {
                var d = get_locale_double(str);
                vlevels[i].cell = (float)d;
                i++;
            }
        }

        if(autocon)
        {
            autocon_cb.active=true;
            mkcon = true;
        }

        if(mwvar == MWChooser.MWVAR.UNDEF)
        {
            mwvar = mwc.get_version(MWChooser.MWVAR.MWOLD);
        }

        if(mwvar == MWChooser.MWVAR.UNDEF)
        {
            remove_window(window);
        }

        start_poll_timer();
        lastp = new Timer();
        anim_cb();

        if(mkcon)
        {
            connect_serial();
        }

        window.set_default_size(conf.window_w, conf.window_h);
        window.show_now();

        var ebox = new Gtk.Box (Gtk.Orientation.HORIZONTAL,2);

        if(conf.window_p == -1)
        {
/*
*** non-deprecated ****
            Gdk.Display dp = Gdk.Display.get_default();
            var mon = dp.get_monitor_at_window(window.get_window());
            var rect = mon.get_geometry();
            conf.window_p = rect.width*80/100;
*/
            var scr = window.get_screen();
            var mon = scr.get_monitor_at_window(scr.get_active_window());
            Gdk.Rectangle monitor;
            scr.get_monitor_geometry(mon, out monitor);
            conf.window_p = monitor.width*80/100;
        }

            // Hack (thanks to Inkscape for the clue) to made pane resize better
        pane.set_resize_mode(Gtk.ResizeMode.QUEUE);
        pane.position = conf.window_p;
        pane.pack1(ebox,true, false);
        pane.add2(box); //, true, true);
        ebox.pack_start (embed, true, true, 0);
        ebox.show_all();

        Timeout.add_seconds(5, () => { return try_connect(); });

        if(set_fs)
            window.fullscreen();
        else if(no_max == false || conf.window_w == -1 || conf.window_h == -1)
            window.maximize();
        else
            window.resize(conf.window_w, conf.window_h);

        window.show_all();
        Timeout.add(500, () => {
                int wd,ht;
                window.get_size(out wd, out ht);
                if (wd > conf.window_p)
                        conf.window_p = wd *70 /100;

                if(pane.position != conf.window_p)
                {
                    pane.position = conf.window_p;
                }
                Timeout.add(250, () => {
                        fbox.allow_resize(false);
                        return Source.REMOVE;
                    });
                return Source.REMOVE;
            });

        window.size_allocate.connect((a) => {
                if(((a.width != conf.window_w) || (a.height != conf.window_h))
                   && (!window.is_maximized)
                   )
                {
                    conf.window_w  = a.width;
                    conf.window_h = a.height;
                    conf.save_window();
                }
            });

        pane.button_press_event.connect((evt) => {
                fbox.allow_resize(true);
                return false;
            });

        pane.button_release_event.connect((evt) => {
                if (evt.button == 1)
                {
                    if(conf.window_p != pane.position)
                    {
                        conf.window_p = pane.position;
                        conf.save_pane();
                    }
                }
                Timeout.add(500, () => {
                        fbox.allow_resize(false);
                        return Source.REMOVE;
                    });
                return false;
            });

        if(!lman.load_init())
        {
            dockitem[DOCKLETS.ARTHOR].iconify_item ();
            dockitem[DOCKLETS.GPS].iconify_item ();
            dockitem[DOCKLETS.NAVSTATUS].iconify_item ();
            dockitem[DOCKLETS.VOLTAGE].iconify_item ();
            dockitem[DOCKLETS.RADIO].iconify_item ();
            dockitem[DOCKLETS.TELEMETRY].iconify_item ();
            dockitem[DOCKLETS.FBOX].iconify_item ();
            lman.save_config();
        }

        mwpdh = new MwpDockHelper(dockitem[DOCKLETS.MISSION], dock,
                          "Mission Editor", conf.tote_floating);
        mwpdh.transient(window);

        fbox.update(true);

        if(conf.mavph != null)
            parse_rc_mav(conf.mavph, Craft.Special.PH);

        if(conf.mavrth != null)
            parse_rc_mav(conf.mavrth, Craft.Special.RTH);

        Gtk.drag_dest_set (embed, Gtk.DestDefaults.ALL,
                           targets, Gdk.DragAction.COPY);

        embed.drag_data_received.connect(
            (ctx, x, y, data, info, time) => {
                string mf = null;
                string sf = null;
                bool bbox = false;
                foreach(var uri in data.get_uris ())
                {
                    try {
                        var f = Filename.from_uri(uri);
                        if (sf == null && f.has_suffix(".TXT"))
                        {
                            sf = f;
                            bbox = true;
                        }
                        else if (sf == null && f.has_suffix(".log"))
                            sf = f;
                        else if (mf == null && f.has_suffix(".mission"))
                            mf = f;
                    } catch (Error e) {
                        MWPLog.message("dnd: %s\n", e.message);
                    }
                }
                Gtk.drag_finish (ctx, true, false, time);
                if(mf != null)
                    load_file(mf);
                if(sf != null)
                {
                    if(bbox)
                        replay_bbox(true, sf);
                    else
                        run_replay(sf, true, Player.MWP);
                }
            });
        setup_buttons();
        if(rfile != null)
        {
            usemag = force_mag;
            Idle.add(() => {
                    run_replay(Posix.realpath(rfile), true, Player.MWP);
                    return false;
                });
        }
        else if(bfile != null)
        {
            usemag = force_mag;
            Idle.add(() => {
                    replay_bbox(true, Posix.realpath(bfile));
                    return false;
                });
        }
    }

    public void build_deventry()
    {
        dev_entry = builder.get_object ("comboboxtext1") as Gtk.ComboBoxText;
        dev_entry.remove_all ();
        foreach(string a in conf.devices)
        {
            dev_entry.append_text(a);
        }
    }

    private void setup_buttons()
    {
        view.button_press_event.connect((evt) => {
                if(evt.button == 1)
                    button_time = evt.time;
                return false;
            });

        Clutter.ModifierType wpmod = 0;
        if(conf.wpmod == 1)
            wpmod = Clutter.ModifierType.CONTROL_MASK;
        else if (conf.wpmod == 2)
            wpmod = Clutter.ModifierType.SHIFT_MASK;

        Clutter.ModifierType wpmod3 = 0;
        if(conf.wpmod3 == 1)
            wpmod3 = Clutter.ModifierType.CONTROL_MASK;
        else if (conf.wpmod == 2)
            wpmod3 = Clutter.ModifierType.SHIFT_MASK;

        view.button_release_event.connect((evt) => {
                bool ret = false;
                if (evt.button == 1)
                {
                    if (((evt.time - button_time) < conf.dwell_time) &&
                        ((evt.modifier_state & wpmod) == wpmod))
                    {
                        insert_new_wp(evt.x, evt.y);
                        ret = true;
                    }
                    else
                    {
                        anim_cb(false);
                    }
                }
                else if (evt.button == 3 &&
                        ((evt.modifier_state & wpmod3) == wpmod3))
                {
                    insert_new_wp(evt.x, evt.y);
                    ret = true;
                }
                return ret;
            });
    }

    private void insert_new_wp(float x, float y)
    {
        var lon = view.x_to_longitude (x);
        var lat = view.y_to_latitude (y);
        ls.insert_item(MSP.Action.WAYPOINT, lat,lon);
        ls.calc_mission();
    }

    private void parse_rc_mav(string s, Craft.Special ptype)
    {
        var parts = s.split(":");
        if(parts.length == 3)
        {
            mavposdef += MavPOSDef() { minval=(uint16)int.parse(parts[1]),
                    maxval=(uint16)int.parse(parts[2]),
                    ptype = ptype,
                    chan = (uint8)int.parse(parts[0]), set =0};
        }
    }

    private void toggle_full_screen()
    {
        if(wdw_state == true)
            window.unfullscreen();
        else
            window.fullscreen();
        mwpdh.transient(window, !wdw_state);
    }

    private bool try_connect()
    {
        if(autocon)
        {
            if(!msp.available)
                connect_serial();
            Timeout.add_seconds(5, () => { return try_connect(); });
            return Source.REMOVE;
        }
        return Source.CONTINUE;
    }

    private void set_error_status(string? e)
    {
        if(e != null)
        {
            MWPLog.message("message => %s\n", e);
            statusbar.push(context_id, e);
            bleet_sans_merci(GENERAL_ALERT);
        }
        else
        {
            statusbar.push(context_id, "");
        }
    }

    private void msg_poller()
    {
        if(dopoll)
        {
            lastp.start();
            send_poll();
        }
    }

    private bool pos_valid(double lat, double lon)
    {
        bool vpos;

        if(have_home)
        {
            if( (Math.fabs(lat - xlat) < 0.25) &&
                (Math.fabs(lon - xlon) < 0.25))
            {
                vpos = true;
                xlat = lat;
                xlon = lon;
            }
            else
            {
                vpos = false;
                if(xlat != 0.0 && xlon != 0.0)
                    MWPLog.message("Ignore bogus %f %f (%f %f)\n",
                                   lat, lon, xlat, xlon);
            }
        }
        else
            vpos = true;
        return vpos;
    }

    private void start_poll_timer()
    {
        var lmin = 0;
        var failcount = 0;

        Timeout.add(TIMINTVL, () =>
            {
                nticks++;
                var tlimit = conf.polltimeout / TIMINTVL;

                if(dopoll)
                {
                    if(looptimer > 0)
                    {
                        var loopc = ((int)(looptimer *1000)) / TIMINTVL;
                        if (loopc > 0 && (nticks % loopc) == 0)
                        {
                            if(tcycle == 0)
                            {
                                failcount = 0;
                                msg_poller();
                            }
                            else
                            {
                                failcount++;
                                telstats.toc++;
                                if (failcount >= tlimit)
                                {
                                    MWPLog.message("TOC0 (%d)\n", tcycle);
                                    failcount = 0;
                                    tcycle = 0;
                                    msg_poller();
                                }
                            }
                        }
                    }
                    else if ((nticks - lastok) > tlimit)
                    {
                        telstats.toc++;
                        MWPLog.message("TOC1 (%d)\n", tcycle);
                        lastok = nticks;
                        tcycle = 0;
                        msg_poller();
                    }
                }
                else
                {
                    if(armed != 0 && msp.available &&
                       gpsintvl != 0 && last_gps != 0)
                    {
                        if (nticks - last_gps > gpsintvl)
                        {
                            if(replayer == Player.NONE)
                                bleet_sans_merci(SAT_ALERT);
                            if(replay_paused == false)
                                MWPLog.message("GPS stalled\n");
                            gpslab.label = "<span foreground = \"red\">⬤</span>";
                            last_gps = nticks;
                        }
                    }

                    if( xdopoll == false &&
                        last_tm > 0 &&
                        ((nticks - last_tm) > MAVINTVL)
                        && msp.available && replayer == Player.NONE)
                    {
                        MWPLog.message("Restart poller on telemetry timeout\n");
                        have_api = have_vers = have_misc =
                        have_status = have_wp = have_nc =
                        have_fcv = have_fcvv = false;
                        xbits = icount = api_cnt = 0;
                        init_sstats();
                        last_tm = 0;
                        lastp.start();
                        add_cmd(MSP.Cmds.IDENT,null,0, 2500);
                    }
                }

                if((nticks % STATINTVL) == 0)
                {
                    gen_serial_stats();
                    telemstatus.update(telstats, item_visible(DOCKLETS.TELEMETRY));
                }

                if(duration != 0 && ((nticks % DURAINTVL) == 0))
                {
                    int mins;
                    int secs;
                    if(duration < 0)
                    {
                        mins = secs = 0;
                        duration = 0;
                    }
                    else
                    {
                        mins = (int)duration / 60;
                        secs = (int)duration % 60;
                        if(mins != lmin)
                        {
                            navstatus.update_duration(mins);
                            lmin = mins;
                        }
                    }
                    elapsedlab.set_text("%02d:%02d".printf(mins,secs));
                }

                if(conf.heartbeat != null && (nticks % BEATINTVL) == 0)
                {
                    try {
                        Process.spawn_command_line_async(conf.heartbeat);
                    } catch  {}
                }
                return Source.CONTINUE;
            });
    }

    private void init_have_home()
    {
        have_home = false;
        markers.negate_rth();
        home_pos.lat = 0;
        home_pos.lon = 0;
        xlon = 0;
        xlat = 0;
        want_special = 0;
    }

    private void send_poll()
    {
        var req=requests[tcycle];
        lastm = nticks;
        if((lastm - lastrx) > NODATAINTVL)
        {
            if(rxerr == false)
            {
                set_error_status("No data for 5 seconds");
                rxerr=true;
            }
                /* Probably takes a minute to change the LIPO */
            if(lastm - lastrx > RESTARTINTVL)
            {
                MWPLog.message("Restart poll loop\n");
                init_state();
                init_sstats();
                dopoll = false;
                init_have_home();
                validatelab.set_text("");
                add_cmd(MSP.Cmds.IDENT,null,0, 2500);
                return;
            }
        }
        else
        {
            if(rxerr)
            {
                set_error_status(null);
                rxerr=false;
            }
        }

        if (req == MSP.Cmds.ANALOG)
        {
            if (lastm - last_an > 40)
            {
                last_an = lastm;
                mavc = 0;
            }
            else
            {
                tcycle = (tcycle + 1) % requests.length;
                req = requests[tcycle];
            }
        }

        if (req == MSP.Cmds.GPSSVINFO)
        {
            if (lastm - last_sv > 40)
            {
                last_sv = lastm;
                mavc = 0;
            }
            else
            {
                tcycle = (tcycle + 1) % requests.length;
                req = requests[tcycle];
            }
        }
        send_cmd(req, null, 0);
    }

    private void init_craft_icon()
    {
        if(craft == null)
        {
            MWPLog.message("init icon %d\n",  vi.mrtype);
            craft = new Craft(view, vi.mrtype,norotate, gps_trail, stack_size);
            craft.park();
        }
    }

    private ulong build_pollreqs()
    {
        ulong reqsize = 0;
        requests.resize(0);

        sensor_alm = false;

        requests += MSP.Cmds.STATUS;
        reqsize += MSize.MSP_STATUS;

        requests += MSP.Cmds.ANALOG;
        reqsize += MSize.MSP_ANALOG;

        sflags = NavStatus.SPK.Volts;

        var missing = 0;

        if(force_mag)
            usemag = true;
        else
        {
            usemag = ((sensor & MSP.Sensors.MAG) == MSP.Sensors.MAG);
            if(!usemag)
                missing = MSP.Sensors.MAG;
        }

        if((sensor & MSP.Sensors.GPS) == MSP.Sensors.GPS)
        {
            sflags |= NavStatus.SPK.GPS;
            if((navcap & NAVCAPS.NAVSTATUS) == NAVCAPS.NAVSTATUS)
            {
                requests += MSP.Cmds.NAV_STATUS;
                reqsize += MSize.MSP_NAV_STATUS;
            }
            requests += MSP.Cmds.RAW_GPS;
            requests += MSP.Cmds.COMP_GPS;
            reqsize += (MSize.MSP_RAW_GPS + MSize.MSP_COMP_GPS);
            init_craft_icon();
        }
        else
            missing |= MSP.Sensors.GPS;

        if((sensor & MSP.Sensors.ACC) == MSP.Sensors.ACC)
        {
            requests += MSP.Cmds.ATTITUDE;
            reqsize += MSize.MSP_ATTITUDE;
        }

        if((sensor & MSP.Sensors.BARO) == MSP.Sensors.BARO)
        {
            sflags |= NavStatus.SPK.BARO;
            requests += MSP.Cmds.ALTITUDE;
            reqsize += MSize.MSP_ALTITUDE;
        }
        else
            missing |= MSP.Sensors.BARO;

        if(missing != 0)
        {
            if(gpscnt < 5)
            {
                string []nsensor={};
                if((missing & MSP.Sensors.GPS) != 0)
                    nsensor += "GPS";
                if((missing & MSP.Sensors.BARO) != 0)
                    nsensor += "BARO";
                if((missing & MSP.Sensors.MAG) != 0)
                    nsensor += "MAG";
                var nss = string.joinv("/",nsensor);
                set_error_status("No %s detected".printf(nss));
                MWPLog.message("no %s, sensor = 0x%x\n", nss, sensor);
                gpscnt++;
            }
        }
        else
        {
            set_error_status(null);
            gpscnt = 0;
        }
        return reqsize;
    }

    private void map_init_warning()
    {
        Clutter.Color red = { 0xff,0,0, 0xff};
        var textb = new Clutter.Actor ();
        clutext = new Clutter.Text.full ("Sans 36", "", red);
        textb.add_child(clutext);
        textb.set_position(40,40);
        view.add_child (textb);
    }

    private void map_show_warning(string text)
    {
        clutext.set_text(text);
    }

    private void map_hide_warning()
    {
        clutext.set_text("");
    }

    private void  alert_broken_sensors(uint8 val)
    {
        if(val != xs_state)
        {
            string sound;
            MWPLog.message("sensor health %04x %d %d\n", sensor, val, xs_state);
            if(val == 1)
            {
                sound = (sensor_alm) ? GENERAL_ALERT : RED_ALERT;
                sensor_alm = true;
                init_craft_icon();
                map_show_warning("SENSOR FAILURE");
            }
            else
            {
                sound = GENERAL_ALERT;
                map_hide_warning();
            }
            bleet_sans_merci(sound);
            navstatus.hw_failure(val);
            xs_state = val;
        }
    }

    private void update_sensor_array()
    {
        alert_broken_sensors((uint8)(sensor >> 15));
        for(int i = 0; i < 5; i++)
        {
            uint16 mask = (1 << i);
            bool setx = ((sensor & mask) != 0);
            sensor_sts[i+1].label = "<span foreground = \"%s\">▌</span>".printf((setx) ? "green" : "red");
        }
        sensor_sts[0].label = sensor_sts[1].label;
    }

    private void clear_sensor_array()
    {
        xs_state = 0;
        for(int i = 0; i < 6; i++)
            sensor_sts[i].label = " ";
    }

    private void reboot_status()
    {
        reboot.sensitive =  (msp != null && msp.available && armed == 0);
        menucli.sensitive =  (msp != null && msp.available && armed == 0);
    }

    private void armed_processing(uint32 flag, string reason="")
    {
        if(armed == 0)
        {
            armtime = 0;
            duration = -1;
            if(replayer == Player.NONE)
                init_have_home();
            no_ofix = 0;
        }
        else
        {
            if(armtime == 0)
                time_t(out armtime);
            time_t(out duration);
            duration -= armtime;
        }

        if(Logger.is_logging)
        {
            Logger.armed((armed == 1), duration, flag,sensor, telem);
        }

        if(armed != larmed)
        {
            radstatus.annul();
            if (armed == 1)
            {
                reboot_status();
                init_craft_icon();
                if(gps_trail)
                {
                    if(craft != null)
                    {
                        markers.remove_rings(view);
                        craft.init_trail();
                    }
                }
                init_have_home();
                MWPLog.message("Armed %x\n", want_special);
                armed_spinner.show();
                armed_spinner.start();
                sflags |= NavStatus.SPK.Volts;

                if (conf.audioarmed == true)
                {
                    audio_cb.active = true;
                }
                if(conf.logarmed == true)
                {
                    logb.active = true;
                }

                if(Logger.is_logging)
                {
                    Logger.armed(true,duration,flag, sensor,telem);
                    if(rhdop != 10000)
                    {
                        LTM_XFRAME xf = LTM_XFRAME();
                        xf = {0};
                        xf.hdop = rhdop;
                        xf.sensorok = (sensor >> 15);
                        Logger.ltm_xframe(xf);
                    }
                }
            }
            else
            {
                MWPLog.message("Disarmed %s\n", reason);
                armed_spinner.stop();
                armed_spinner.hide();
                duration = -1;
                armtime = 0;
                want_special = 0;
                init_have_home();
                if (conf.audioarmed == true)
                {
                    audio_cb.active = false;
                }
                if(conf.logarmed == true)
                {
                    if(Logger.is_logging)
                        Logger.armed(false,duration,flag, sensor,telem);
                    logb.active=false;
                }
                navstatus.reset_states();
                reboot_status();
            }
        }
        larmed = armed;
    }

    private void reset_poller(bool remove = true)
    {
        if(remove)
            remove_tid(ref upltid);
        lastok = nticks;
        dopoll = xdopoll;
        xdopoll = false;
        if(dopoll)
            msg_poller();
    }

    private void gps_alert(uint8 scflags)
    {
        bool urgent = ((scflags & SAT_FLAGS.URGENT) != 0);
        bool beep = ((scflags & SAT_FLAGS.BEEP) != 0);
        navstatus.sats(_nsats, urgent);
        if(beep && replayer == Player.NONE)
            bleet_sans_merci(SAT_ALERT);
        nsats = _nsats;
        last_ga = lastrx;
    }

    private void sat_coverage()
    {
        uint8 scflags = 0;
        if(nsats != _nsats)
        {
            if(_nsats < SATS.MINSATS)
            {
                if(_nsats < nsats)
                {
                    scflags = SAT_FLAGS.URGENT|SAT_FLAGS.BEEP;
                }
                else if((lastrx - last_ga) > USATINTVL)
                {
                    scflags = SAT_FLAGS.URGENT;
                }
            }
            else
            {
                if(nsats < SATS.MINSATS)
                    scflags = SAT_FLAGS.URGENT;
                else if((lastrx - last_ga) > UUSATINTVL)
                {
                    scflags = SAT_FLAGS.NEEDED;
                }
            }
        }

        if((scflags == 0) && ((lastrx - last_ga) > SATINTVL))
        {
            scflags = SAT_FLAGS.NEEDED;
        }

        if(scflags != SAT_FLAGS.NONE)
            gps_alert(scflags);
    }

    private void flash_gps()
    {
        gpslab.label = "<span foreground = \"%s\">⬤</span>".printf(conf.led);
        Timeout.add(50, () =>
            {
//                gpslab.label = "<span foreground = \"black\">⬤</span>";
                gpslab.set_label("◯");
                return false;
            });
    }

    private string board_by_id()
    {
        string board="";
        switch (vi.board)
        {
            case "FYF3":
                board = "FURYF3";
                break;
            case "AIR3":
                board = "AIRHEROF3";
                break;
            case "AFNA":
                board = "NAZE";
                break;
            case "AWF3":
                board = "ALIENWIIF3";
                break;
            case "OLI1":
                board = "OLIMEXINO";
                break;
            case "OBSD":
                board = "OMNIBUSF4";
                break;
            case "OBF4":
                board = "OMNIBUSF4";
                break;
            case "BJF4":
                board = "BLUEJAYF4";
                break;
            case "CLBR":
                board = "COLIBRI_RACE";
                break;
            case "COLI":
                board = "COLIBRI";
                break;
            case "PIKO":
                board = "PIKOBLX";
                break;
            case "SRF3":
                board = "SPRACINGF3";
                break;
            case "ABF4":
                board = "AIRBOTF4";
                break;
            case "CJM1":
                board = "CJMCU";
                break;
            case "SDF3":
                board = "STM32F3DISCOVERY";
                break;
            case "RMDO":
                board = "RMDO";
                break;
            case "SPKY":
                board = "SPARKY";
                break;
            case "YPF4":
                board = "YUPIF4";
                break;
            case "PXR4":
                board = "PIXRACER";
                break;
            case "ANY7":
                board = "ANYFCF7";
                break;
            case "F4BY":
                board = "F4BY";
                break;
            case "CPM1":
                board = "CRAZEPONYMINI";
                break;
            case "MOTO":
                board = "MOTOLAB";
                break;
            case "SPEV":
                board = "SPRACINGF3EVO";
                break;
            case "EUF1":
                board = "EUSTM32F103RC";
                break;
            case "REF3":
                board = "RCEXPLORERF3";
                break;
            case "SPK2":
                board = "SPARKY2";
                break;
            case "REVO":
                board = "REVO";
                break;
            case "ANYF":
                board = "ANYFC";
                break;
            case "SRFM":
                board = "SPRACINGF3MINI";
                break;
            case "LUX" :
                board = "LUX_RACE";
                break;
            case "FDV1":
                board = "FISHDRONEF4";
                break;
            case "AFF3":
                board = "ALIENFLIGHTF3";
                break;
            case "103R":
                board = "PORT103R";
                break;
            case "CHF3":
                board = "CHEBUZZF3";
                break;
            case "OMNI":
                board = "OMNIBUS";
                break;
            case "CC3D":
                board = "CC3D";
                break;
        }
        return board;
    }

    private void handle_msp_status(uint8[]raw)
    {
        uint32 bxflag;

        deserialise_u16(raw+4, out sensor);
        deserialise_u32(raw+6, out bxflag);
        var lmask = (angle_mask|horz_mask);
        armed = ((bxflag & arm_mask) == arm_mask) ? 1 : 0;

        if (nopoll == true)
        {
            have_status = true;
            if((sensor & MSP.Sensors.GPS) == MSP.Sensors.GPS)
            {
                sflags |= NavStatus.SPK.GPS;
                init_craft_icon();
            }
        }
        else
        {
            if(have_status == false)
            {
                have_status = true;
                StringBuilder sb0 = new StringBuilder ();
                foreach (MSP.Sensors sn in MSP.Sensors.all())
                {
                    if((sensor & sn) == sn)
                    {
                        sb0.append(sn.to_string());
                        sb0.append(" ");
                    }
                }
                MWPLog.message("Sensors: %s (%04x)\n", sb0.str, sensor);

                if(!prlabel)
                {
                    profile = raw[10];
                    prlabel = true;
                    var lab = verlab.get_label();
                    StringBuilder sb = new StringBuilder();
                    sb.append(lab);
                    if(naze32 && vi.fc_api[0] != 0)
                        sb.append(" API %d.%d".printf(vi.fc_api[0],vi.fc_api[1]));
                    if(navcap != NAVCAPS.NONE)
                        sb.append(" Nav");
                    sb.append(" Pr %d".printf(raw[10]));
                    verlab.set_label(sb.str);
                }

                want_special = 0;
                if(replayer == Player.NONE)
                {
                    if(conf.checkswitches &&
                       ((bxflag & lmask) == 0) && robj == null)
                    {
                        MWPLog.message("switch val == %0x\n", bxflag);
                        swd.run();
                    }
                    if((navcap & NAVCAPS.NAVCONFIG) == NAVCAPS.NAVCONFIG)
                        add_cmd(MSP.Cmds.NAV_CONFIG,null,0,1000);
                    else if ((navcap & (NAVCAPS.INAV_MR|NAVCAPS.INAV_FW)) != 0)
                        add_cmd(MSP.Cmds.NAV_POSHOLD,null,0,1000);
                }

                var reqsize = build_pollreqs();
                var nreqs = requests.length;
                int timeout = (int)(looptimer*1000 / nreqs);

                    // data we send, response is structs + this
                var qsize = nreqs * 6;
                reqsize += qsize;
                if(naze32)
                    qsize += 1; // for WP no

                MWPLog.message("Timer cycle for %d (%dms) items, %lu => %lu bytes\n",
                               nreqs,timeout,qsize,reqsize);

                if(nopoll == false && nreqs > 0)
                {
                    if  (replayer == Player.NONE)
                    {
                        MWPLog.message("Start poller\n");
                        tcycle = 0;
                        dopoll = true;
                        start_audio();
                    }
                }
                report_bits(bxflag);
                Craft.RMIcon ri = 0;
                if ((rth_mask != 0) && ((bxflag & rth_mask) == 0))
                    ri |= Craft.RMIcon.RTH;
                if ((ph_mask != 0) && ((bxflag & ph_mask) == 0))
                    ri |= Craft.RMIcon.PH;
                if ((wp_mask != 0) && ((bxflag & wp_mask) == 0))
                    ri |= Craft.RMIcon.WP;
                if(ri != 0 && craft != null)
                    craft.remove_special(ri);
            }
            else
            {
                if(gpscnt != 0 && ((sensor & MSP.Sensors.GPS) == MSP.Sensors.GPS))
                {
                    build_pollreqs();
                }
                if(sensor != xsensor)
                {
                    update_sensor_array();
                    xsensor = sensor;
                }
            }

                // acro/horizon/angle changed

            if((bxflag & lmask) != (xbits & lmask))
            {
                report_bits(bxflag);
            }

            if(armed != 0)
            {
                if ((rth_mask != 0) &&
                    ((bxflag & rth_mask) != 0) &&
                    ((xbits & rth_mask) == 0))
                {
                    MWPLog.message("set RTH on %08x %u %ds\n", bxflag,bxflag,
                                   (int)duration);
                    want_special |= POSMODE.RTH;
                }
                else if ((ph_mask != 0) &&
                         ((bxflag & ph_mask) != 0) &&
                         ((xbits & ph_mask) == 0))
                {
                    MWPLog.message("set PH on %08x %u %ds\n", bxflag, bxflag,
                                   (int)duration);
                    want_special |= POSMODE.PH;
                }
                else if ((wp_mask != 0) &&
                         ((bxflag & wp_mask) != 0) &&
                         ((xbits & wp_mask) == 0))
                {
                    MWPLog.message("set WP on %08x %u %ds\n", bxflag, bxflag,
                                   (int)duration);
                    want_special |= POSMODE.WP;
                }
                else if ((xbits != bxflag) && craft != null)
                {
                    craft.set_normal();
                }
            }
            xbits = bxflag;
        }
        armed_processing(bxflag,"msp");
    }

    private void centre_mission(Mission ms, bool ctr_on)
    {
        MissionItem [] mis = ms.get_ways();
        if(mis.length > 0)
        {
            ms.maxx = ms.maxy = -999.0;
            ms.minx = ms.miny = 999.0;
            foreach(MissionItem mi in mis)
            {
                if(mi.action != MSP.Action.RTH &&
                   mi.action != MSP.Action.JUMP &&
                   mi.action != MSP.Action.SET_HEAD)
                {
                    if (mi.lat > ms.maxy)
                        ms.maxy = mi.lat;
                    if (mi.lon > ms.maxx)
                        ms.maxx = mi.lon;
                    if (mi.lat <  ms.miny)
                        ms.miny = mi.lat;
                    if (mi.lon <  ms.minx)
                        ms.minx = mi.lon;
                }
            }
            ms.zoom = view.get_max_zoom_level();
            ms.cy = (ms.maxy + ms.miny) / 2.0;
            ms.cx = (ms.maxx + ms.minx) / 2.0;
            if (ctr_on)
                view.center_on(ms.cy, ms.cx);
        }
    }

    public void handle_serial(MSP.Cmds cmd, uint8[] raw, uint len, bool errs)
    {
        if(cmd > MSP.Cmds.LTM_BASE)
        {
            telem = true;
            if (replayer != Player.MWP && cmd != MSP.Cmds.MAVLINK_MSG_ID_RADIO)
            {
                if(nopoll == false)
                {
                    dopoll = false;
                }
                if (errs == false)
                {
                    if(last_tm == 0)
                    {
                        MWPLog.message("LTM/Mavlink mode\n");
                        remove_tid(ref cmdtid);
                        init_sstats();
                        if(naze32 != true)
                        {
                            naze32 = true;
                            mwvar = vi.fctype = MWChooser.MWVAR.CF;
                            var vers="CF Telemetry";
                            verlab.set_label(vers);
                        }
                    }
                    last_tm = nticks;
                    last_gps = nticks;
                }
            }
        }
        else
            telem = false;

        if(errs == true)
        {
            remove_tid(ref cmdtid);
            stdout.printf("Error on cmd %s %d\n", cmd.to_string(), cmd);
            switch(cmd)
            {
                case MSP.Cmds.NAV_CONFIG:
                    navcap = NAVCAPS.NONE;
                    break;
                case MSP.Cmds.API_VERSION:
                case MSP.Cmds.FC_VARIANT:
                case MSP.Cmds.FC_VERSION:
                    add_cmd(MSP.Cmds.BOXNAMES, null,0, 1000);
                    break;
                default:
                    break;
            }
            return;
        }
        if(Logger.is_logging)
            Logger.log_time();

        if(cmd != MSP.Cmds.RADIO)
            lastrx = lastok = nticks;

        switch(cmd)
        {
            case MSP.Cmds.API_VERSION:
                remove_tid(ref cmdtid);
                have_api = true;
                if(len > 32)
                {
                    naze32 = true;
                    mwvar = vi.fctype = MWChooser.MWVAR.CF;
                    var vers="CF mwc %03d".printf(vi.mvers);
                    verlab.set_label(vers);
                    add_cmd(MSP.Cmds.BOXNAMES,null,0,1000);
                }
                else
                {
                    vi.fc_api[0] = raw[1];
                    vi.fc_api[1] = raw[2];
                    add_cmd(MSP.Cmds.BOARD_INFO,null,0,1000);
                }
                break;

            case MSP.Cmds.BOARD_INFO:
                raw[4]=0;
                vi.board = (string)raw[0:3];
                add_cmd(MSP.Cmds.FC_VARIANT,null,0,1000);
                break;

            case MSP.Cmds.FC_VARIANT:
                remove_tid(ref cmdtid);
                naze32 = true;
                raw[4] = 0;
                inav = false;
                vi.fc_var = (string)raw[0:4];
                if (have_fcv == false)
                {
                    have_fcv = true;
                    switch(vi.fc_var)
                    {
                        case "CLFL":
                        case "BTFL":
                            vi.fctype = mwvar = MWChooser.MWVAR.CF;
                            add_cmd(MSP.Cmds.FC_VERSION,null,0,1000);
                            break;
                        case "INAV":
                            navcap = NAVCAPS.WAYPOINTS|NAVCAPS.NAVSTATUS;
                            if (vi.mrtype == Craft.Vehicles.FLYING_WING
                                || vi.mrtype == Craft.Vehicles.AIRPLANE
                                || vi.mrtype == Craft.Vehicles.CUSTOM_AIRPLANE)
                                navcap |= NAVCAPS.INAV_FW;
                            else
                                navcap |= NAVCAPS.INAV_MR;
                            vi.fctype = mwvar = MWChooser.MWVAR.CF;
                            inav = true;
                            add_cmd(MSP.Cmds.FC_VERSION,null,0,1000);
                            break;
                        default:
                            add_cmd(MSP.Cmds.BOXNAMES,null,0,1000);
                            break;
                    }
                }
                break;

            case MSP.Cmds.FC_VERSION:
                remove_tid(ref cmdtid);
                if(have_fcvv == false)
                {
                    have_fcvv = true;
                    vi.fc_vers = raw[0:3];
                    var fcv = "%s v%d.%d.%d".printf(vi.fc_var,raw[0],raw[1],raw[2]);
                    verlab.set_label(fcv);
                    if(inav)
                    {
                        mission_eeprom = (vi.board != "AFNA" &&
                                          vi.board != "CC3D" &&
                                          raw[0] >= 1 && raw[1] >= 6);
                        add_cmd(MSP.Cmds.BUILD_INFO, null, 0, 1000);
                    }
                    else
                        add_cmd(MSP.Cmds.BOXNAMES,null,0,1000);
                }
                break;

            case MSP.Cmds.BUILD_INFO:
                remove_tid(ref cmdtid);
                uint8 gi[16] = raw[19:len];
                gi[len-19] = 0;
                vi.fc_git = (string)gi;
                var board = board_by_id();
                var vers = "%s %s (%s)".printf(verlab.get_label(), board,
                                               vi.fc_git);
                verlab.set_label(vers);
                MWPLog.message("%s\n", vers);
                add_cmd(MSP.Cmds.BOXNAMES,null,0,1000);
                break;

            case MSP.Cmds.IDENT:
                last_gps = 0;
                remove_tid(ref cmdtid);
                have_vers = true;
                if (icount == 0)
                {
                    vi = {0};
                    vi.mvers = raw[0];
                    vi.mrtype = raw[1];
                    if(dmrtype != vi.mrtype)
                    {
                        dmrtype = vi.mrtype;
                        if(craft != null)
                            craft.set_icon(vi.mrtype);
                    }
                    prlabel = false;

                    deserialise_u32(raw+3, out capability);

                    MWPLog.message("set mrtype=%u cap =%x\n", vi.mrtype, raw[3]);
                    MWChooser.MWVAR _mwvar = mwvar;

                    if(mwvar == MWChooser.MWVAR.AUTO)
                    {
                        naze32 = ((capability & MSPCaps.CAP_PLATFORM_32BIT) != 0);
                    }
                    else
                    {
                        naze32 = mwvar == MWChooser.MWVAR.CF;
                    }

                    if(naze32 == true)
                    {
                        if(force_nc == false)
                            navcap = NAVCAPS.NONE;
                    }
                    else
                    {
                        navcap = ((raw[3] & 0x10) == 0x10) ?
                            NAVCAPS.WAYPOINTS|NAVCAPS.NAVSTATUS|NAVCAPS.NAVCONFIG
                            : NAVCAPS.NONE;
                    }
                    if(mwvar == MWChooser.MWVAR.AUTO)
                    {
                        if(naze32)
                        {
                            _mwvar = MWChooser.MWVAR.CF;
                        }
                        else
                        {
                            _mwvar = (navcap != NAVCAPS.NONE) ? MWChooser.MWVAR.MWNEW : MWChooser.MWVAR.MWOLD;
                        }
                    }
                    vi.fctype = mwvar;
                    var vers="%s v%03d".printf(MWChooser.mwnames[_mwvar], vi.mvers);
                    verlab.set_label(vers);
                    typlab.set_label(MSP.get_mrtype(vi.mrtype));
                    add_cmd(MSP.Cmds.API_VERSION,null,0,1000);
                }
                icount++;
                break;

            case MSP.Cmds.BOXNAMES:
                if(navcap != NAVCAPS.NONE)
                    menuup.sensitive = menudown.sensitive = true;
                var ncbits = (navcap & (NAVCAPS.NAVCONFIG|NAVCAPS.INAV_MR|NAVCAPS.INAV_FW));
                if (ncbits != 0)
                {
                    menuncfg.sensitive = true;
                    if(mission_eeprom)
                        menustore.sensitive = menurestore.sensitive = true;
                    MWPLog.message("Generate navconf %x\n", navcap);
                    navconf.setup(ncbits);
                    if((navcap & NAVCAPS.NAVCONFIG) == NAVCAPS.NAVCONFIG)
                        navconf.mw_navconf_event.connect((mw,nc) => {
                                mw_update_config(nc);
                            });
                    if((navcap & NAVCAPS.INAV_MR) == NAVCAPS.INAV_MR)
                        navconf.mr_nav_poshold_event.connect((mw,pcfg) => {
                                mr_update_config(pcfg);
                            });
                }

                remove_tid(ref cmdtid);
                raw[len] = 0;
                boxnames = (string)raw;
                string []bsx = ((string)raw).split(";");
                int i = 0;
                foreach(var bs in bsx)
                {
                    switch(bs)
                    {
                        case "ARM":
                            arm_mask = (1 << i);
                            break;
                        case "ANGLE":
                            angle_mask = (1 << i);
                            break;
                        case "HORIZON":
                            horz_mask = (1 << i);
                            break;
                        case "GPS HOME":
                        case "NAV RTH":
                            rth_mask = (1 << i);
                            break;
                        case "GPS HOLD":
                        case "NAV POSHOLD":
                            ph_mask = (1 << i);
                            break;
                        case "NAV WP":
                        case "MISSION":
                            wp_mask = (1 << i);
                            break;
                    }
                    i++;
                }
                MWPLog.message("Masks arm %x angle %x horz %x ph %x rth %x wp %x\n",
                               arm_mask, angle_mask, horz_mask, ph_mask,
                               rth_mask, wp_mask);
                add_cmd(MSP.Cmds.MISC,null,0, 1000);
                break;

            case MSP.Cmds.GPSSTATISTICS:
                LTM_XFRAME xf = LTM_XFRAME();
                deserialise_u16(raw+14, out xf.hdop);
                rhdop = xf.hdop;
                gpsinfo.set_hdop(xf.hdop/100.0);
                if(Logger.is_logging)
                {
                    Logger.ltm_xframe(xf);
                }
                break;

            case MSP.Cmds.MISC:
                remove_tid(ref cmdtid);
                have_misc = true;
                vwarn1 = raw[19];
                send_cmd(MSP.Cmds.WP_GETINFO, null, 0);
                Timeout.add(250, () => {
                        add_cmd(MSP.Cmds.STATUS,null,0, 1000);
                        return Source.REMOVE;
                    });
                break;

            case MSP.Cmds.STATUS:
                remove_tid(ref cmdtid);
                handle_msp_status(raw);
                break;

            case MSP.Cmds.WP_GETINFO:
                var wpi = MSP_WP_GETINFO();
                uint8* rp = raw;
                rp++;
                wp_max = wpi.max_wp = *rp++;
                wpi.wps_valid = *rp++;
                wpi.wp_count = *rp;
                MWPLog.message("Waypoint Info : %u %u %u\n",
                               wpi.max_wp, wpi.wps_valid, wpi.wp_count);

                if((wpmgr.wp_flag & WPDL.GETINFO) != 0 && wpi.wps_valid == 0)
                {
                    string s = "FC invalidates mission (%u WP)".printf(wpi.wp_count);
                    mwp_warning_box(s, Gtk.MessageType.ERROR, 10);
                    wpmgr.wp_flag |= ~WPDL.GETINFO;
                }
                else if (wpi.wp_count > 0 && wpi.wps_valid == 1 )
                {
                    string s = "Waypoints in FC\nMax: %u Valid: %u Points: %u".printf(wpi.max_wp, wpi.wps_valid, wpi.wp_count);
                    mwp_warning_box(s, Gtk.MessageType.INFO, 5);
                    if(stslabel.get_text() == "No mission")
                    {
                        stslabel.set_text("%u WP valid in FC".printf(wpi.wp_count));
                        validatelab.set_text("✔"); // u+2714
                    }
                }
                break;

            case MSP.Cmds.NAV_STATUS:
            case MSP.Cmds.TN_FRAME:
            {
                MSP_NAV_STATUS ns = MSP_NAV_STATUS();
                uint8 flg = 0;
                uint8* rp = raw;
                ns.gps_mode = *rp++;
                if(ns.gps_mode == 15)
                {
                    if (nticks - last_crit > CRITINTVL)
                    {
                        bleet_sans_merci(GENERAL_ALERT);
                        MWPLog.message("GPS Critial Failure!!!\n");
                        navstatus.gps_crit();
                        last_crit = nticks;
                    }
                }
                else
                    last_crit = 0;

                ns.nav_mode = *rp++;
                ns.action = *rp++;
                ns.wp_number = *rp++;
                ns.nav_error = *rp++;
                if(cmd == MSP.Cmds.NAV_STATUS)
                    deserialise_u16(rp, out ns.target_bearing);
                else
                {
                    flg = 1;
                    ns.target_bearing = *rp++;
                }
                navstatus.update(ns,item_visible(DOCKLETS.NAVSTATUS),flg);
            }
            break;

            case MSP.Cmds.NAV_POSHOLD:
                remove_tid(ref cmdtid);
                have_nc = true;
                MSP_NAV_POSHOLD poscfg = MSP_NAV_POSHOLD();
                uint8* rp = raw;
                poscfg.nav_user_control_mode = *rp++;
                rp = deserialise_u16(rp, out poscfg.nav_max_speed);
                rp = deserialise_u16(rp, out poscfg.nav_max_climb_rate);
                rp = deserialise_u16(rp, out poscfg.nav_manual_speed);
                rp = deserialise_u16(rp, out poscfg.nav_manual_climb_rate);
                poscfg.nav_mc_bank_angle = *rp++;
                poscfg.nav_use_midthr_for_althold = *rp++;
                rp = deserialise_u16(rp, out poscfg.nav_mc_hover_thr);
                navconf.mr_update(poscfg);
                ls.set_mission_speed(poscfg.nav_max_speed / 100.0);
                if (ls.lastid > 0)
                    ls.calc_mission();
                break;

            case MSP.Cmds.NAV_CONFIG:
                remove_tid(ref cmdtid);
                have_nc = true;
                MSP_NAV_CONFIG nc = MSP_NAV_CONFIG();
                uint8* rp = raw;
                nc.flag1 = *rp++;
                nc.flag2 = *rp++;
                rp = deserialise_u16(rp, out nc.wp_radius);
                rp = deserialise_u16(rp, out nc.safe_wp_distance);
                rp = deserialise_u16(rp, out nc.nav_max_altitude);
                rp = deserialise_u16(rp, out nc.nav_speed_max);
                rp = deserialise_u16(rp, out nc.nav_speed_min);
                nc.crosstrack_gain = *rp++;
                rp = deserialise_u16(rp, out nc.nav_bank_max);
                rp = deserialise_u16(rp, out nc.rth_altitude);
                nc.land_speed = *rp++;
                rp = deserialise_u16(rp, out nc.fence);
                nc.max_wp_number = *rp;
                navconf.mw_update(nc);
                ls.set_mission_speed(nc.nav_speed_max / 100.0);
                if (ls.lastid > 0)
                    ls.calc_mission();
                break;

            case MSP.Cmds.SET_NAV_CONFIG:
                MWPLog.message("RX set nav config\n");
                send_cmd(MSP.Cmds.EEPROM_WRITE,null, 0);
                break;

            case MSP.Cmds.COMP_GPS:
                MSP_COMP_GPS cg = MSP_COMP_GPS();
                uint8* rp;
                rp = deserialise_u16(raw, out cg.range);
                rp = deserialise_i16(rp, out cg.direction);
                cg.update = *rp;
                navstatus.comp_gps(cg,item_visible(DOCKLETS.NAVSTATUS));
                break;

            case MSP.Cmds.ATTITUDE:
                MSP_ATTITUDE at = MSP_ATTITUDE();
                uint8* rp;
                rp = deserialise_i16(raw, out at.angx);
                rp = deserialise_i16(rp, out at.angy);
                deserialise_i16(rp, out at.heading);
                if(usemag)
                {
                    mhead = at.heading;
                    if(mhead < 0)
                        mhead += 360;
                }
                navstatus.set_attitude(at,item_visible(DOCKLETS.NAVSTATUS));
                art_win.update(at.angx, at.angy, item_visible(DOCKLETS.ARTHOR));

                if((sensor & MSP.Sensors.GPS) == 0)
                    fbox.update(item_visible(DOCKLETS.FBOX));
                break;

            case MSP.Cmds.ALTITUDE:
                MSP_ALTITUDE al = MSP_ALTITUDE();
                uint8* rp;
                rp = deserialise_i32(raw, out al.estalt);
                deserialise_i16(rp, out al.vario);
                navstatus.set_altitude(al, item_visible(DOCKLETS.NAVSTATUS));
                break;

            case MSP.Cmds.ANALOG:
                MSP_ANALOG an = MSP_ANALOG();
                an.vbat = raw[0];
                if(!have_mspradio)
                {
                    deserialise_i16(raw+3, out an.rssi);
                    radstatus.update_rssi(an.rssi, item_visible(DOCKLETS.RADIO));
                }
                if(Logger.is_logging)
                {
                    Logger.analog(an);
                }
                var ivbat = an.vbat;
                set_bat_stat(ivbat);
                break;

            case MSP.Cmds.RAW_GPS:
                MSP_RAW_GPS rg = MSP_RAW_GPS();
                uint8* rp = raw;
                rg.gps_fix = *rp++;
                if(rg.gps_fix != 0)
                {
                    if(replayer == Player.NONE)
                    {
                        if(inav)
                            rg.gps_fix++;
                    }
                    else
                        last_gps = nticks;
                }
                flash_gps();

                rg.gps_numsat = *rp++;
                rp = deserialise_i32(rp, out rg.gps_lat);
                rp = deserialise_i32(rp, out rg.gps_lon);
                rp = deserialise_i16(rp, out rg.gps_altitude);
                rp = deserialise_u16(rp, out rg.gps_speed);
                rp = deserialise_u16(rp, out rg.gps_ground_course);
                if(len == 18)
                {
                    deserialise_u16(rp, out rg.gps_hdop);
                    rhdop = rg.gps_hdop;
                    gpsinfo.set_hdop(rg.gps_hdop/100.0);
                }
                gpsfix = (gpsinfo.update(rg, conf.dms, item_visible(DOCKLETS.GPS)) != 0);
                fbox.update(item_visible(DOCKLETS.FBOX));
                _nsats = rg.gps_numsat;

                if (gpsfix)
                {
                    sat_coverage();
                    if(armed == 1)
                    {
                        if(have_home == false && home_changed(GPSInfo.lat, GPSInfo.lon))
                        {
                            sflags |=  NavStatus.SPK.GPS;
                            want_special |= POSMODE.HOME;
                            navstatus.cg_on();
                        }
                    }

                    if(craft != null)
                    {
                        if(pos_valid(GPSInfo.lat, GPSInfo.lon))
                        {
                            if(follow == true)
                            {
                                double cse = (usemag) ? mhead : GPSInfo.cse;
                                craft.set_lat_lon(GPSInfo.lat, GPSInfo.lon,cse);
                            }
                            if (centreon == true)
                            {
                                view.center_on(GPSInfo.lat,GPSInfo.lon);
                                anim_cb();
                            }
                        }
                    }
                    if(want_special != 0)
                        process_pos_states(GPSInfo.lat,GPSInfo.lon,
                                           rg.gps_altitude, "RAW GPS");
                }
                break;

            case MSP.Cmds.SET_WP:
                if(wpmgr.wps.length > 0)
                {
                    var no = wpmgr.wps[wpmgr.wpidx].wp_no;
                    request_wp(no);
                }
                else
                    wpmgr.wp_flag = WPDL.REPLAY;
                break;

            case MSP.Cmds.WP:
                remove_tid(ref cmdtid);
                have_wp = true;
                MSP_WP w = MSP_WP();
                uint8* rp = raw;

                if((wpmgr.wp_flag & WPDL.POLL) == 0)
                {
                    w.wp_no = *rp++;
                    w.action = *rp++;
                    rp = deserialise_i32(rp, out w.lat);
                    rp = deserialise_i32(rp, out w.lon);
                    rp = deserialise_i32(rp, out w.altitude);
                    rp = deserialise_i16(rp, out w.p1);
                    rp = deserialise_u16(rp, out w.p2);
                    rp = deserialise_u16(rp, out w.p3);
                    w.flag = *rp;
                }

                if ((wpmgr.wp_flag & WPDL.VALIDATE) != 0  ||
                    (wpmgr.wp_flag & WPDL.SAVE_EEPROM) != 0)
                {
                    WPFAIL fail = WPFAIL.OK;
                    validatelab.set_text("WP:%3d".printf(w.wp_no));
                    if(w.wp_no != wpmgr.wps[wpmgr.wpidx].wp_no)
                        fail |= WPFAIL.NO;
                    else if(w.action != wpmgr.wps[wpmgr.wpidx].action)
                        fail |= WPFAIL.ACT;
                    else if (w.lat != wpmgr.wps[wpmgr.wpidx].lat)
                        fail |= WPFAIL.LAT;
                    else if (w.lon != wpmgr.wps[wpmgr.wpidx].lon)
                            fail |= WPFAIL.LON;
                    else if (w.altitude != wpmgr.wps[wpmgr.wpidx].altitude)
                        fail |= WPFAIL.ALT;
                    else if (w.p1 != wpmgr.wps[wpmgr.wpidx].p1)
                        fail |= WPFAIL.P1;
                    else if (w.p2 != wpmgr.wps[wpmgr.wpidx].p2)
                        fail |= WPFAIL.P2;
                    else if (w.p3 != wpmgr.wps[wpmgr.wpidx].p3)
                        fail |= WPFAIL.P3;
                    else if (w.flag != wpmgr.wps[wpmgr.wpidx].flag)
                    {
                        fail |= WPFAIL.FLAG;
                    }

                    if (fail != WPFAIL.OK)
                    {
                        if((debug_flags & DEBUG_FLAGS.WP) != DEBUG_FLAGS.NONE)
                        {
                            stderr.printf("WP size %d [read,expect]\n", (int)len);
                            stderr.printf("no %d %d\n",
                                          w.wp_no, wpmgr.wps[wpmgr.wpidx].wp_no);
                            stderr.printf("action %d %d\n",
                                          w.action, wpmgr.wps[wpmgr.wpidx].action);
                            stderr.printf("lat %d %d\n",
                                          w.lat, wpmgr.wps[wpmgr.wpidx].lat);
                            stderr.printf("lon %d %d\n",
                                          w.lon, wpmgr.wps[wpmgr.wpidx].lon);
                            stderr.printf("alt %u %u\n",
                                          w.altitude, wpmgr.wps[wpmgr.wpidx].altitude);
                            stderr.printf("p1 %d %d\n",
                                          w.p1, wpmgr.wps[wpmgr.wpidx].p1);
                            stderr.printf("p2 %d %d\n",
                                          w.p2, wpmgr.wps[wpmgr.wpidx].p2);
                            stderr.printf("p3 %d %d\n",
                                          w.p3, wpmgr.wps[wpmgr.wpidx].p3);
                            stderr.printf("flag %x %x\n",
                                          w.flag, wpmgr.wps[wpmgr.wpidx].flag);
                        }
                        StringBuilder sb = new StringBuilder();
                        for(var i = 0; i < failnames.length; i += 1)
                        {
                            if ((fail & (1 <<i)) == (1 << i))
                            {
                                sb.append(failnames[i]);
                                sb.append(" ");
                            }
                        }
                        MWPCursor.set_normal_cursor(window);
                        reset_poller();
                        var mtxt = "Validation for wp %d fails for %s".printf(w.wp_no, sb.str);
                        bleet_sans_merci(GENERAL_ALERT);
                        validatelab.set_text("⚠"); // u+26a0
                        mwp_warning_box(mtxt, Gtk.MessageType.ERROR);
                    }
                    else if(w.flag != 0xa5)
                    {
                        wpmgr.wpidx++;
                        uint8 wtmp[64];
                        var nb = serialise_wp(wpmgr.wps[wpmgr.wpidx], wtmp);
                        send_cmd(MSP.Cmds.SET_WP, wtmp, nb);
                    }
                    else
                    {
                        MWPCursor.set_normal_cursor(window);
                        bleet_sans_merci(GENERAL_ALERT);
                        validatelab.set_text("✔"); // u+2714
                        mwp_warning_box("Mission validated", Gtk.MessageType.INFO,5);
                        if((wpmgr.wp_flag & WPDL.SAVE_EEPROM) != 0)
                        {
                            uint8 zb=0;
                            send_cmd(MSP.Cmds.WP_MISSION_SAVE, &zb, 1);
                        }

                        Timeout.add(250, () => {
                                wpmgr.wp_flag |= WPDL.GETINFO;
                                send_cmd(MSP.Cmds.WP_GETINFO, null, 0);
                                return Source.REMOVE;
                            });
                        Timeout.add(500, () => {
                                reset_poller(true);
                                return Source.REMOVE;
                            });
                    }
                }
                else if ((wpmgr.wp_flag & WPDL.REPLACE) != 0 ||
                         (wpmgr.wp_flag & WPDL.REPLAY) != 0)
                {
                    validatelab.set_text("WP:%3d".printf(w.wp_no));
                    MissionItem m = MissionItem();
                    m.no= w.wp_no;
                    m.action = (MSP.Action)w.action;
                    m.lat = w.lat/10000000.0;
                    m.lon = w.lon/10000000.0;
                    m.alt = w.altitude/100;
                    m.param1 = w.p1;
                    if(m.action == MSP.Action.SET_HEAD &&
                       conf.recip_head  == true && m.param1 != -1)
                    {
                        m.param1 = (m.param1 + 180) % 360;
                    }
                    m.param2 = w.p2;
                    m.param3 = w.p3;

                    wp_resp += m;
                    if(w.flag == 0xa5 || w.wp_no == 255)
                    {
                        MWPCursor.set_normal_cursor(window);
                        if((debug_flags & DEBUG_FLAGS.WP) != DEBUG_FLAGS.NONE)
                            stderr.printf("Null mission returned\n");
                        var ms = new Mission();
                        if(w.wp_no == 1 && m.action == MSP.Action.RTH
                           && w.lat == 0 && w.lon == 0)
                        {
                            ls.clear_mission();
                        }
                        else
                        {
                            ms.set_ways(wp_resp);
                            ls.import_mission(ms);
                            centre_mission(ms, !centreon);
                            markers.add_list_store(ls);
                            validatelab.set_text("✔"); // u+2714

                        }
                        wp_resp={};
                        reset_poller();
                    }
                    else if(w.flag == 0xfe)
                    {
                        MWPCursor.set_normal_cursor(window);
                        MWPLog.message("Error flag on wp #%d\n", w.wp_no);
                    }
                    else
                    {
                        request_wp(w.wp_no+1);
                    }
                }
                else
                {
                    MWPCursor.set_normal_cursor(window);
                    MWPLog.message("unsolicited WP #%d\n", w.wp_no);
                }
                break;

            case MSP.Cmds.EEPROM_WRITE:
                break;

            case MSP.Cmds.RADIO:
                if(!ignore_3dr)
                {
                    have_mspradio = true;
                    handle_radio(raw);
                }
                break;

            case MSP.Cmds.MAVLINK_MSG_ID_RADIO:
                handle_radio(raw);
                break;

            case MSP.Cmds.TO_FRAME:
                LTM_OFRAME of = LTM_OFRAME();
                uint8* rp;
                rp = deserialise_i32(raw, out of.lat);
                rp = deserialise_i32(rp, out of.lon);
                of.fix = *(rp+5);
                double gflat = of.lat/10000000.0;
                double gflon = of.lon/10000000.0;

                if(home_changed(gflat, gflon))
                {
                    if(of.fix == 0)
                    {
                        no_ofix++;
                    }
                    else
                    {
                        navstatus.cg_on();
                        sflags |=  NavStatus.SPK.GPS;
                        want_special |= POSMODE.HOME;
                        process_pos_states(gflat, gflon, 0.0, "LTM OFrame");
                    }
                }
                if(Logger.is_logging)
                {
                    Logger.ltm_oframe(of);
                }
                break;

            case MSP.Cmds.TG_FRAME:
            {
                sflags |=  NavStatus.SPK.ELEV;
                LTM_GFRAME gf = LTM_GFRAME();
                uint8* rp;

                flash_gps();
                last_gps = nticks;

                rp = deserialise_i32(raw, out gf.lat);
                rp = deserialise_i32(rp, out gf.lon);

                gf.speed = *rp++;
                rp = deserialise_i32(rp, out gf.alt);
                gf.sats = *rp;
                init_craft_icon();
                MSP_ALTITUDE al = MSP_ALTITUDE();
                al.estalt = gf.alt;
                al.vario = 0;
                navstatus.set_altitude(al, item_visible(DOCKLETS.NAVSTATUS));

                int fix = gpsinfo.update_ltm(gf, conf.dms, item_visible(DOCKLETS.GPS), rhdop);
                _nsats = (gf.sats >> 2);

                if((_nsats == 0 && nsats != 0) || (nsats == 0 && _nsats != 0))
                {
                    nsats = _nsats;
                    navstatus.sats(_nsats, true);
                }

                if(fix > 0)
                {
                    double gflat = gf.lat/10000000.0;
                    double gflon = gf.lon/10000000.0;

                    sat_coverage();

                    if(armed != 0)
                    {
                        if(have_home)
                        {
                            if(_nsats >= SATS.MINSATS)
                            {
                                double dist,cse;
                                Geo.csedist(gflat, gflon,
                                            home_pos.lat, home_pos.lon,
                                            out dist, out cse);
                                if(dist < 64)
                                {
                                    var cg = MSP_COMP_GPS();
                                    cg.range = (uint16)Math.lround(dist*1852);
                                    cg.direction = (int16)Math.lround(cse);
                                    navstatus.comp_gps(cg, item_visible(DOCKLETS.NAVSTATUS));
                                }
                            }
                        }
                        else
                        {
                            if(no_ofix == 10)
                            {
                                MWPLog.message("No home position yet\n");
                            }
                        }
                    }

                    if(craft != null && fix > 0 && _nsats >= 5)
                    {
                        if(pos_valid(gflat, gflon))
                        {
                            if(follow == true)
                                craft.set_lat_lon(gflat,gflon,gfcse);
                            if (centreon == true)
                            {
                                view.center_on(gflat,gflon);
                                anim_cb();
                            }
                        }
                    }
                    if(want_special != 0)
                        process_pos_states(gflat, gflon, gf.alt/100.0, "GFrame");
                }
                fbox.update(item_visible(DOCKLETS.FBOX));
            }
            break;

            case MSP.Cmds.TX_FRAME:
                uint8* rp;
                LTM_XFRAME xf = LTM_XFRAME();
                rp = deserialise_u16(raw, out rhdop);
                xf.hdop = rhdop;
                xf.sensorok = *rp++;
                xf.ltm_x_count = *rp++;
                xf.disarm_reason = *rp;

                alert_broken_sensors(xf.sensorok);
                gpsinfo.set_hdop(rhdop/100.0);
                if(Logger.is_logging)
                    Logger.ltm_xframe(xf);

                if(armed == 0 && xf.disarm_reason != 0 &&
                   xf.disarm_reason < disarm_reason.length)
                    MWPLog.message("LTM Disarm (armed = %d) reason %s\n",
                                   armed, disarm_reason[xf.disarm_reason]);
                break;

            case MSP.Cmds.TA_FRAME:
            {
                LTM_AFRAME af = LTM_AFRAME();
                uint8* rp;
                rp = deserialise_i16(raw, out af.pitch);
                rp = deserialise_i16(rp, out af.roll);
                rp = deserialise_i16(rp, out af.heading);
                var h = af.heading;
                if(h < 0)
                    h += 360;
                gfcse = h;
                navstatus.update_ltm_a(af, item_visible(DOCKLETS.NAVSTATUS));
                art_win.update(af.roll*10, af.pitch*10, item_visible(DOCKLETS.ARTHOR));
            }
            break;

            case MSP.Cmds.TS_FRAME:
            {
                LTM_SFRAME sf = LTM_SFRAME ();
                uint8* rp;
                rp = deserialise_i16(raw, out sf.vbat);
                rp = deserialise_i16(rp, out sf.vcurr);
                sf.rssi = *rp++;
                sf.airspeed = *rp++;
                sf.flags = *rp++;
                radstatus.update_ltm(sf,item_visible(DOCKLETS.RADIO));

                uint8 ltmflags = sf.flags >> 2;
                uint32 mwflags = 0;
                uint8 saf = sf.flags & 1;
                bool failsafe = ((sf.flags & 2)  == 2);

                if(xfailsafe != failsafe)
                {
                    if(failsafe)
                        map_show_warning("FAILSAFE");
                    else
                        map_hide_warning();
                    xfailsafe = failsafe;
                }

                if ((saf & 1) == 1)
                {
                    mwflags = arm_mask;
                    armed = 1;
                    dac = 0;
                }
                else
                {
                    dac++;
                    if(dac == 1)
                    {
                        MWPLog.message("Disarm from LTM\n");
                        mwflags = 0;
                        armed = 0;
                        init_have_home();
                        /* schedule the bubble machine again .. */
                        if(replayer == Player.NONE)
                        {
                            reset_poller(false);
                        }
                    }
                }
                if(ltmflags == 2)
                    mwflags |= angle_mask;
                if(ltmflags == 3)
                    mwflags |= horz_mask;
                if(ltmflags == 3)
                    mwflags |= arm_mask;
                if(ltmflags == 9)
                    mwflags |= ph_mask;
                if(ltmflags == 10)
                    mwflags |= wp_mask;
                if(ltmflags == 13 || ltmflags == 15)
                    mwflags |= rth_mask;
                else
                    mwflags = xbits; // don't know better

                armed_processing(mwflags,"ltm");
                var xws = want_special;
                if(ltmflags != last_ltmf)
                {
                    last_ltmf = ltmflags;
                    if(ltmflags == 9)
                        want_special |= POSMODE.PH;
                    else if(ltmflags == 10)
                        want_special |= POSMODE.WP;
                    else if(ltmflags == 13)
                        want_special |= POSMODE.RTH;
                    else if(ltmflags != 15)
                    {
                        MWPLog.message("LTM set normal\n");
                        craft.set_normal();
                    }
                    MWPLog.message("New LTM Mode %s (%d) %d %ds %f %f %x %x\n",
                                   MSP.ltm_mode(ltmflags), ltmflags,
                                   armed, duration, xlat, xlon,
                                   xws, want_special);
                }
                if(want_special != 0 /* && have_home*/)
                    process_pos_states(xlat,xlon, 0, "SFrame");

                navstatus.update_ltm_s(sf, item_visible(DOCKLETS.NAVSTATUS));
                set_bat_stat((uint8)((sf.vbat + 50) / 100));
            }
            break;

            case MSP.Cmds.MAVLINK_MSG_ID_HEARTBEAT:
                Mav.MAVLINK_HEARTBEAT m = *(Mav.MAVLINK_HEARTBEAT*)raw;
                force_mav = false;
                if(mavc == 0 &&  msp.available)
                    send_mav_heartbeat();
                mavc++;
                mavc %= 64;

                if(craft == null)
                {
                    Mav.mav2mw(m.type);
                    init_craft_icon();
                }

                if ((m.base_mode & 128) == 128)
                    armed = 1;
                else
                    armed = 0;
                sensor = mavsensors;
                armed_processing(armed,"mav");

                if(Logger.is_logging)
                    Logger.mav_heartbeat(m);
                break;

            case MSP.Cmds.MAVLINK_MSG_ID_SYS_STATUS:
                Mav.MAVLINK_SYS_STATUS m = *(Mav.MAVLINK_SYS_STATUS*)raw;
                if(sflags == 1)
                {
                    mavsensors = 1;
                    if((m.onboard_control_sensors_health & 0x8) == 0x8)
                    {
                        sflags |= NavStatus.SPK.BARO;
                        mavsensors |= MSP.Sensors.BARO;
                    }
                    if((m.onboard_control_sensors_health & 0x20) == 0x20)
                    {
                        sflags |= NavStatus.SPK.GPS;
                        mavsensors |= MSP.Sensors.GPS;
                    }
                    if((m.onboard_control_sensors_health & 0x4)== 0x4)
                    {
                        mavsensors |= MSP.Sensors.MAG;
                    }
                }
                set_bat_stat(m.voltage_battery/100);
                if(Logger.is_logging)
                    Logger.mav_sys_status(m);
                break;

            case MSP.Cmds.MAVLINK_MSG_GPS_GLOBAL_INT:
                break;

            case MSP.Cmds.MAVLINK_MSG_GPS_RAW_INT:
                Mav.MAVLINK_GPS_RAW_INT m = *(Mav.MAVLINK_GPS_RAW_INT*)raw;
                var fix  = gpsinfo.update_mav_gps(m, conf.dms,
                                                item_visible(DOCKLETS.GPS));
                gpsfix = (fix > 1);
                _nsats = m.satellites_visible;

                if(gpsfix)
                {
                    if(armed == 1)
                    {
                        if(have_home == false)
                        {
                            sflags |=  NavStatus.SPK.GPS;
                            navstatus.cg_on();
                        }
                        else
                        {
                            double dist,cse;
                            Geo.csedist(GPSInfo.lat, GPSInfo.lon,
                                        home_pos.lat, home_pos.lon,
                                        out dist, out cse);
                            var cg = MSP_COMP_GPS();
                            cg.range = (uint16)Math.lround(dist*1852);
                            cg.direction = (int16)Math.lround(cse);
                            navstatus.comp_gps(cg, item_visible(DOCKLETS.NAVSTATUS));
                        }
                    }
                    if(craft != null)
                    {
                        if(pos_valid(GPSInfo.lat, GPSInfo.lon))
                        {
                            if(follow == true)
                            {
                                double cse = (usemag) ? mhead : GPSInfo.cse;
                                craft.set_lat_lon(GPSInfo.lat, GPSInfo.lon,cse);
                            }
                            if (centreon == true)
                            {
                                view.center_on(GPSInfo.lat,GPSInfo.lon);
                                anim_cb();
                            }
                        }
                        if(want_special != 0)
                            process_pos_states(GPSInfo.lat, GPSInfo.lon,
                                               m.alt/1000.0, "MavGPS");
                    }
                }
                fbox.update(item_visible(DOCKLETS.FBOX));
                break;

            case MSP.Cmds.MAVLINK_MSG_ATTITUDE:
                Mav.MAVLINK_ATTITUDE m = *(Mav.MAVLINK_ATTITUDE*)raw;
                if(usemag)
                {
                    mhead = (int16)(m.yaw*RAD2DEG);
                    if(mhead < 0)
                        mhead += 360;
                }
                navstatus.set_mav_attitude(m,item_visible(DOCKLETS.NAVSTATUS));
                art_win.update((int16)(m.roll*57.29578*10), (int16)(m.pitch*57.29578*10),
                               item_visible(DOCKLETS.ARTHOR));
                break;

            case MSP.Cmds.MAVLINK_MSG_RC_CHANNELS_RAW:
                for (var j = 0; j < mavposdef.length; j++)
                {
                    if(mavposdef[j].chan != 0)
                    {
                        var offset = mavposdef[j].chan+1;
                        uint16 val = *(((uint16*)raw)+offset);
                        if(val > mavposdef[j].minval && val < mavposdef[j].maxval)
                        {
                            if(mavposdef[j].set == 0)
                            {
                                if (mavposdef[j].ptype == Craft.Special.PH)
                                    want_special |= POSMODE.PH;
                                else if (mavposdef[j].ptype == Craft.Special.RTH)
                                    want_special |= POSMODE.RTH;
                            }
                            mavposdef[j].set = 1;
                        }
                        else
                        {
                            mavposdef[j].set = 0;
                        }
                    }
                }
                if(Logger.is_logging)
                {
                    Mav.MAVLINK_RC_CHANNELS m = *(Mav.MAVLINK_RC_CHANNELS*)raw;
                    Logger.mav_rc_channels(m);
                    radstatus.update_rssi(m.rssi,item_visible(DOCKLETS.RADIO));
                }
                break;

            case MSP.Cmds.MAVLINK_MSG_GPS_GLOBAL_ORIGIN:
                Mav. MAVLINK_GPS_GLOBAL_ORIGIN m = *(Mav.MAVLINK_GPS_GLOBAL_ORIGIN *)raw;
                var ilat  = m.latitude / 10000000.0;
                var ilon  = m.longitude / 10000000.0;

                if(want_special != 0)
                    process_pos_states(ilat, ilon, m.altitude / 1000.0, "MAvOrig");

                if(Logger.is_logging)
                {
                    Logger.mav_gps_global_origin(m);
                }
                break;

            case MSP.Cmds.MAVLINK_MSG_VFR_HUD:
                Mav.MAVLINK_VFR_HUD m = *(Mav.MAVLINK_VFR_HUD *)raw;
                mhead = (int16)m.heading;
                navstatus.set_mav_altitude(m, item_visible(DOCKLETS.NAVSTATUS));
                break;

            case MSP.Cmds.MAVLINK_MSG_ID_RADIO_STATUS:
                break;
            case MSP.Cmds.REBOOT:
                MWPLog.message("Reboot scheduled\n");
                serial_doom(conbutton);
                Timeout.add(4000, () => {
                        if(!msp.available && !autocon)
                        {
                            MWPLog.message("Reconnecting\n");
                            connect_serial();
                        }
                        return Source.REMOVE;
                    });
                break;

            case MSP.Cmds.TQ_FRAME:
                cleanup_replay();
                break;

            case MSP.Cmds.SET_NAV_POSHOLD:
                send_cmd(MSP.Cmds.EEPROM_WRITE,null, 0);
                Timeout.add(250,() => {
                        add_cmd(MSP.Cmds.NAV_POSHOLD,null,0, 1000);
                        Timeout.add(250,() => {
                                reset_poller();
                                return Source.REMOVE;
                            });
                        return Source.REMOVE;
                    });
                break;
            case MSP.Cmds.WP_MISSION_LOAD:
                download_mission();
                break;
            default:
                MWPLog.message ("** Unknown response %d (%dbytes)\n", cmd, len);
                break;
        }

        if(dopoll)
        {
            if (match_pollcmds(cmd))
            {
                if (requests.length > 0)
                    tcycle = (tcycle + 1) % requests.length;
                if(tcycle == 0)
                {
                    lastp.stop();
                    var et = lastp.elapsed();
                    telstats.tot = (looptimer == 0) ? 0 :
                        (int)((looptimer-et)*1000);
                    acycle += (uint64)(et*1000);
                    anvals++;
                    if(looptimer == 0)
                        msg_poller();
                }
                else
                {
                    send_poll();
                }
            }
        }
    }

    private bool match_pollcmds(MSP.Cmds cmd)
    {
        bool matched=false;
        foreach(var c in requests)
        {
            if (c == cmd)
            {
                matched = true;
                break;
            }
        }
        return matched;
    }

    private bool home_changed(double lat, double lon)
    {
        bool ret=false;
        if(((Math.fabs(home_pos.lat - lat) > 1e-6) ||
           Math.fabs(home_pos.lon - lon) > 1e-6))
        {
            if(have_home && (home_pos.lat != 0.0) && (home_pos.lon != 0.0))
            {
                double d,cse;
                Geo.csedist(lat, lon, home_pos.lat, home_pos.lon, out d, out cse);
                d*=1852.0;
                if(d > conf.max_home_delta)
                {
                    bleet_sans_merci(GENERAL_ALERT);
                    navstatus.alert_home_moved();
                    MWPLog.message(
                        "Established home has jumped %.1fm [%f %f (ex %f %f)]",
                        d, lat, lon, home_pos.lat, home_pos.lon);
                }
            }
            home_pos.lat = lat;
            home_pos.lon = lon;
            have_home = true;
            ret = true;
        }
        return ret;
    }

    private void process_pos_states(double lat, double lon, double alt,
                                    string? reason=null)
    {
        if (lat == 0.0 && lon == 0.0)
        {
            want_special = 0;
            return;
        }

        if((armed != 0) && ((want_special & POSMODE.HOME) != 0))
        {
            have_home = true;
            want_special &= ~POSMODE.HOME;
            home_pos.lat = xlat = lat;
            home_pos.lon = xlon = lon;
            home_pos.alt = alt;
            if(ls.have_rth)
                markers.add_rth_point(lat,lon,ls);
            init_craft_icon();
            if(craft != null)
            {
                if(nrings != 0)
                    markers.initiate_rings(view, lat,lon, nrings, ringint,
                                           conf.rcolstr);
                craft.special_wp(Craft.Special.HOME, lat, lon);
            }
            else
            {
                init_have_home();
            }

            if(chome)
                view.center_on(lat,lon);

            StringBuilder sb = new StringBuilder ();
            if(reason != null)
            {
                sb.append(reason);
                sb.append(" ");
            }
            sb.append(have_home.to_string());
            MWPLog.message("Set home %f %f (%s)\n", lat, lon, sb.str);
        }

        if((want_special & POSMODE.PH) != 0)
        {
            want_special &= ~POSMODE.PH;
            MWPLog.message("Set poshold %f %f\n", lat, lon);
            ph_pos.lat = lat;
            ph_pos.lon = lon;
            ph_pos.alt = alt;
            init_craft_icon();
            if(craft != null)
                craft.special_wp(Craft.Special.PH, lat, lon);
        }
        if((want_special & POSMODE.RTH) != 0)
        {
            want_special &= ~POSMODE.RTH;
            rth_pos.lat = lat;
            rth_pos.lon = lon;
            rth_pos.alt = alt;
            init_craft_icon();
            if(craft != null)
                craft.special_wp(Craft.Special.RTH, lat, lon);
        }
        if((want_special & POSMODE.WP) != 0)
        {
            want_special &= ~POSMODE.WP;
            init_craft_icon();
            if(craft != null)
                craft.special_wp(Craft.Special.WP, lat, lon);
        }
    }

    private void handle_radio(uint8[] raw)
    {
        MSP_RADIO r = MSP_RADIO();
        uint8 *rp;
        rp = deserialise_u16(raw, out r.rxerrors);
        rp = deserialise_u16(rp, out r.fixed_errors);
        r.localrssi = *rp++;
        r.remrssi = *rp++;
        r.txbuf = *rp++;
        r.noise = *rp++;
        r.remnoise = *rp;
        radstatus.update(r,item_visible(DOCKLETS.RADIO));
    }

    private void send_mav_heartbeat()
    {
        uint8 mbuf[32];
        mbuf[0] = 0xfe;
        mbuf[1] = 9; // size
        mbuf[2] = 0;
        mbuf[3] = 0;
        mbuf[4] = 0;
        mbuf[5] = 0;
        for(var j =0; j < 9; j++)
            mbuf[6+j] = 0;

        uint8 length = mbuf[1];
        uint16 sum = 0xFFFF;
        uint8 i, stoplen;
        stoplen = length + 6;
        mbuf[length+6] = 50;
        stoplen++;

        i = 1;
        while (i<stoplen)
        {
            sum = msp.mavlink_crc(sum, mbuf[i]);
            i++;
        }
        mbuf[length+6] = (uint8)sum&0xFF;
        mbuf[length+7] = sum>>8;
        msp.write(mbuf,length+8);
    }

    private void report_bits(uint32 bits)
    {
        string mode = null;
        if((bits & angle_mask) == angle_mask)
        {
            mode = "Angle";
        }
        else if((bits & horz_mask) == horz_mask)
        {
            mode = "Horizon";
        }
        else if((bits & (ph_mask | rth_mask)) == 0)
        {
            mode = "Acro";
        }
        if(mode != null)
        {
            fmodelab.set_label(mode);
            navstatus.update_fmode(mode);
        }
    }

    private size_t serialise_wp(MSP_WP w, uint8[] tmp)
    {
        uint8* rp = tmp;
        *rp++ = w.wp_no;
        *rp++ = w.action;
        rp = serialise_i32(rp, w.lat);
        rp = serialise_i32(rp, w.lon);
        rp = serialise_u32(rp, w.altitude);
        rp = serialise_u16(rp, w.p1);
        rp = serialise_u16(rp, w.p2);
        rp = serialise_u16(rp, w.p3);
        *rp++ = w.flag;
        return (rp-&tmp[0]);
    }

    private void bleet_sans_merci(string sfn=RED_ALERT)
    {
        var fn = MWPUtils.find_conf_file(sfn);
        if(fn != null)
        {
            if(use_gst)
            {
                Gst.Element play = Gst.ElementFactory.make ("playbin", "player");
                File file = File.new_for_path (fn);
                var uri = file.get_uri ();
                MWPLog.message("alert %s\n", uri);
                play.set("uri", uri);
                play.set("volume", 5.0);
                play.set_state (Gst.State.PLAYING);
            }
            else
            {
                MWPLog.message("alert %s\n", fn);
                StringBuilder sb = new StringBuilder();
                sb.append(conf.mediap);
                sb.append(" ");
                sb.append(fn);
                try {
                    use_gst = !Process.spawn_command_line_async (sb.str);
                } catch (SpawnError e) {
                    use_gst = true;
                }
            }
        }
    }

    private void init_battery(uint8 ivbat)
    {
        nsampl = 0;
        var ncells = ivbat / 37;
        for(var i = 0; i < vlevels.length; i++)
        {
            vlevels[i].limit = vlevels[i].cell*ncells;
            vlevels[i].reached = false;
        }
        vinit = true;
        vwarn1 = 0;
    }

    private void set_bat_stat(uint8 ivbat)
    {
        if(ivbat < 10)
            return;

        string vbatlab;
        float  vf = (float)ivbat/10.0f;
        if (nsampl == MAXVSAMPLE)
        {
            for(var i = 1; i < MAXVSAMPLE; i++)
                vbsamples[i-1] = vbsamples[i];
        }
        else
            nsampl += 1;

        vbsamples[nsampl-1] = vf;
        vf = 0;
        for(var i = 0; i < nsampl; i++)
            vf += vbsamples[i];
        vf /= nsampl;

        int icol = 0;
        if (ivbat > 0)
        {
            if(vinit == false)
                init_battery(ivbat);

            foreach(var v in vlevels)
            {
                if(vf >= v.limit)
                    break;
                icol += 1;
            }
        }
        else
            icol = vlevels.length-1;

        string str;
        if(vlevels[icol].label == null)
        {
            str = "%.1fv".printf(vf);
        }
        else
            str = vlevels[icol].label;

        var colr = vlevels[icol].colour;
        vbatlab="<span background=\"%s\" weight=\"bold\">%s</span>".printf(
             colr, str);
        labelvbat.set_markup(vbatlab);
        navstatus.volt_update(str,icol,vf,item_visible(DOCKLETS.VOLTAGE));

        if(vlevels[icol].reached == false)
        {
            vlevels[icol].reached = true;
            if(vlevels[icol].audio != null)
            {
                if(replayer == Player.NONE)
                    bleet_sans_merci(vlevels[icol].audio);
                else
                    MWPLog.message("battery alarm %.1f\n", vf);
            }
        }
        licol= icol;
    }

    private void upload_mission(WPDL flag)
    {
        validatelab.set_text("");

        var wps = ls.to_wps(inav, (vi.mrtype == Craft.Vehicles.FLYING_WING
                                   || vi.mrtype == Craft.Vehicles.AIRPLANE
                                   || vi.mrtype == Craft.Vehicles.CUSTOM_AIRPLANE));

        if(wps.length > wp_max)
        {
            string str = "Number of waypoints (%d) exceeds max (%d)".printf(
                wps.length, wp_max);
            mwp_warning_box(str, Gtk.MessageType.ERROR);
            return;
        }

        MWPCursor.set_busy_cursor(window);
    xdopoll = dopoll;
        dopoll = false;

        if(wps.length == 0)
        {
            MSP_WP w0 = MSP_WP();
            w0.wp_no = 1;
            w0.action =  MSP.Action.RTH;
            w0.lat = w0.lon = 0;
            w0.altitude = 25;
            w0.p1 = 0;
            w0.p2 = w0.p3 = 0;
            w0.flag = 0xa5;
            wps += w0;
        }

        if(conf.recip_head)
        {
            for(var ix = 0 ; ix < wps.length; ix++)
            {
                if(wps[ix].action == MSP.Action.SET_HEAD && wps[ix].p1 != -1)
                {
                    wps[ix].p1 = (wps[ix].p1 + 180) % 360;
                }
            }
        }

        wpmgr.npts = (uint8)wps.length;
        wpmgr.wpidx = 0;
        wpmgr.wps = wps;
        wpmgr.wp_flag = flag;

        var timeo = 1500+(wps.length*1000);
        uint8 wtmp[64];
        var nb = serialise_wp(wpmgr.wps[wpmgr.wpidx], wtmp);
        Timeout.add(250, () => {
                send_cmd(MSP.Cmds.SET_WP, wtmp, nb);
                start_wp_timer(timeo);
                return false;
            });
    }

    public void start_wp_timer(uint timeo, string reason="WP")
    {
        upltid = Timeout.add(timeo, () => {
                MWPCursor.set_normal_cursor(window);
                reset_poller(false);
                MWPLog.message("%s operation probably failed\n", reason);
                string wmsg = "%s operation timeout.\nThe upload has probably failed".printf(reason);
                mwp_warning_box(wmsg, Gtk.MessageType.ERROR);
                return Source.REMOVE;
            });
    }

    public void request_wp(uint8 wp)
    {
        uint8 buf[2];
        have_wp = false;
        buf[0] = wp;
        add_cmd(MSP.Cmds.WP,buf,1, 1000);
    }

    private size_t serialise_nc (MSP_NAV_CONFIG nc, uint8[] tmp)
    {
        uint8* rp = tmp;

        *rp++ = nc.flag1;
        *rp++ = nc.flag2;

        rp = serialise_u16(rp, nc.wp_radius);
        rp = serialise_u16(rp, nc.safe_wp_distance);
        rp = serialise_u16(rp, nc.nav_max_altitude);
        rp = serialise_u16(rp, nc.nav_speed_max);
        rp = serialise_u16(rp, nc.nav_speed_min);
        *rp++ = nc.crosstrack_gain;
        rp = serialise_u16(rp, nc.nav_bank_max);
        rp = serialise_u16(rp, nc.rth_altitude);
        *rp++ = nc.land_speed;
        rp = serialise_u16(rp, nc.fence);
        *rp++ = nc.max_wp_number;
        return (rp-&tmp[0]);
    }

    private size_t serialise_pcfg (MSP_NAV_POSHOLD pcfg, uint8[] tmp)
    {
        uint8* rp = tmp;

        *rp++ = pcfg.nav_user_control_mode;
        rp = serialise_u16(rp, pcfg.nav_max_speed);
        rp = serialise_u16(rp, pcfg.nav_max_climb_rate);
        rp = serialise_u16(rp, pcfg.nav_manual_speed);
        rp = serialise_u16(rp, pcfg.nav_manual_climb_rate);
        *rp++ = pcfg.nav_mc_bank_angle;
        *rp++ = pcfg.nav_use_midthr_for_althold;
        rp = serialise_u16(rp, pcfg.nav_mc_hover_thr);
        return (rp-&tmp[0]);
    }

    private void mw_update_config(MSP_NAV_CONFIG nc)
    {
        have_nc = false;
        uint8 tmp[64];
        var nb = serialise_nc(nc, tmp);
        send_cmd(MSP.Cmds.SET_NAV_CONFIG, tmp, nb);
        add_cmd(MSP.Cmds.NAV_CONFIG,null,0, 1000);
    }

    private void mr_update_config(MSP_NAV_POSHOLD pcfg)
    {
        have_nc = false;
        uint8 tmp[64];
        var nb = serialise_pcfg(pcfg, tmp);
        xdopoll = dopoll;
        dopoll = false;
        Timeout.add(250, () => {
                start_wp_timer(2500,"NavCfg");
                send_cmd(MSP.Cmds.SET_NAV_POSHOLD, tmp, nb);
                return Source.REMOVE;
            });
    }

    private void send_cmd(MSP.Cmds cmd, void* buf, size_t len)
    {
        if(msp.available == true)
        {
            msp.send_command(cmd,buf,len);
        }
    }

    private void add_cmd(MSP.Cmds cmd, void* buf, size_t len, int wait=1000)
    {
        remove_tid(ref cmdtid);
        if(msp.available == true)
        {
            cmdtid = Timeout.add(wait, () => {
                    MWPLog.message(" ** repeat %s\n", cmd.to_string());
                    if ((cmd == MSP.Cmds.API_VERSION) ||
                        (cmd == MSP.Cmds.FC_VARIANT) ||
                        (cmd == MSP.Cmds.FC_VERSION))
                        cmd = MSP.Cmds.BOXNAMES;
                    send_cmd(cmd,buf,len);
                    return Source.CONTINUE;
                });
            send_cmd(cmd,buf,len);
        }
    }

    private void start_audio()
    {
        if (spktid == 0)
        {
            if(audio_on /*&& (sflags != 0)*/)
            {
                navstatus.logspeak_init(conf.evoice, (conf.uilang == "ev"),
                                        sndstr);
                spktid = Timeout.add_seconds(conf.speakint, () => {
                        if(replay_paused == false)
                            navstatus.announce(sflags, conf.recip);
                        return Source.CONTINUE;
                    });
                gps_alert(0);
                navstatus.announce(sflags,conf.recip);
            }
        }
    }

    private void stop_audio()
    {
        if(spktid > 0)
        {
            remove_tid(ref spktid);
            navstatus.logspeak_close();
        }
    }

    private void remove_tid(ref uint tid)
    {
        if(tid > 0)
            Source.remove(tid);
        tid = 0;
    }

    private void  gen_serial_stats()
    {
        if(msp.available)
            telstats.s = msp.dump_stats();
        telstats.avg = (anvals > 0) ? (ulong)(acycle/anvals) : 0;
    }

    private void show_serial_stats()
    {
        gen_serial_stats();
        MWPLog.message("%.0fs, rx %lub, tx %lub, (%.0fb/s, %0.fb/s) to %d wait %d, avg poll loop %lu ms messages %s\n",
                       telstats.s.elapsed, telstats.s.rxbytes, telstats.s.txbytes,
                       telstats.s.rxrate, telstats.s.txrate,
                       telstats.toc, telstats.tot, telstats.avg ,
                       telstats.s.msgs.to_string());
    }

    private void serial_doom(Gtk.Button c)
    {
        MWPLog.message("Serial doom replay %d\n", replayer);
        if(replayer == Player.NONE)
        {
            menumwvar.sensitive =true;
            dopoll = false;
            remove_tid(ref cmdtid);
            sflags = 0;
            if (conf.audioarmed == true)
            {
                audio_cb.active = false;
            }
            show_serial_stats();
            if(rawlog == true)
            {
                msp.raw_logging(false);
            }

            gpsinfo.annul();
            navstatus.annul();
            fbox.annul();
            art_win.update(0, 0, item_visible(DOCKLETS.ARTHOR));
            set_bat_stat(0);
            nsats = 0;
            _nsats = 0;
            last_tm = 0;
            last_ga = 0;
            boxnames = null;
            msp.close();
            c.set_label("Connect");
            menustore.sensitive = menurestore.sensitive =
                menuncfg.sensitive = menuup.sensitive = menudown.sensitive = false;
            navconf.hide();
            duration = -1;
            if(craft != null)
            {
                craft.remove_marker();
            }
            init_have_home();
            set_error_status(null);
            xsensor = 0;
            clear_sensor_array();
            validatelab.set_text("");
        }
        else
        {
            replayer = Player.NONE;
        }
        menubblog.sensitive = menubbload.sensitive = menureplay.sensitive =
        menuloadlog.sensitive = true;
        reboot_status();
    }

    private void init_sstats()
    {
        if(telstats.s.msgs != 0)
            gen_serial_stats();
        anvals = acycle = 0;
        telstats.toc = telstats.tot = 0;
        telstats.avg = 0;
        telemstatus.annul();
        radstatus.annul();
    }

    private void init_state()
    {
        map_hide_warning();
        xfailsafe = false;
        dopoll = false;
        have_api = have_vers = have_misc = have_status = have_wp = have_nc =
            have_fcv = have_fcvv = false;
        xbits = icount = api_cnt = 0;
        autocount = 0;
        nsats = 0;
        gpsinfo.annul();
        navstatus.reset();
        art_win.update(0, 0, item_visible(DOCKLETS.ARTHOR));
        vinit = false;
        set_bat_stat(0);
        gpscnt = 0;
        have_mspradio = false;
        force_mav = false;
        want_special = 0;
        xsensor = 0;
        nsampl = 0;
        clear_sensor_array();
        ls.set_mission_speed(conf.nav_speed);
    }

    private void connect_serial()
    {
        if(msp.available)
        {
            serial_doom(conbutton);
            markers.remove_rings(view);
            verlab.set_label("");
            typlab.set_label("");
            statusbar.push(context_id, "");
        }
        else
        {
            var serdev = dev_entry.get_active_text();
            string estr;
            if (msp.open(serdev, conf.baudrate, out estr) == true)
            {
                MWPLog.message("Connected %s\n", serdev);
                menubblog.sensitive = menubbload.sensitive = menureplay.sensitive =
                menuloadlog.sensitive = false;

                validatelab.set_text("");
                init_state();
                init_sstats();
                dopoll = false;
                if(rawlog == true)
                {
                    msp.raw_logging(true);
                }
                conbutton.set_label("Disconnect");
                if(nopoll == false)
                {
                    var timeo = 10;
                    if(serdev.contains("rfcomm"))
                        timeo = 2000;
                    Timeout.add(timeo, () =>
                        {
                            add_cmd(MSP.Cmds.IDENT,null,0, 1500);
                            return Source.REMOVE;
                        });
                }
                menumwvar.sensitive = false;
            }
            else
            {
                if (autocon == false || autocount == 0)
                {
                    mwp_warning_box("Unable to open serial device: %s\nReason: %s\nPlease verify you are a member of the owning group\nTypically \"dialout\" or \"uucp\"".printf(serdev, estr));
                }
                autocount = ((autocount + 1) % 4);
            }
            reboot_status();
        }
    }

    private void anim_cb(bool forced=false)
    {
        var x = view.get_center_longitude();
        var y = view.get_center_latitude();

        if (forced || (lx !=  x && ly != y))
        {
            poslabel.set_text(PosFormat.pos(y,x,conf.dms));
            lx = x;
            ly = y;
            if (follow == false && craft != null)
            {
                double plat,plon;
                craft.get_pos(out plat, out plon);
                var bbox = view.get_bounding_box();
                if (bbox.covers(plat, plon) == false)
                {
                    craft.park();
                }
            }
        }
    }

    private void add_source_combo(string? defmap, MapSource []msources)
    {
        var combo  = builder.get_object ("combobox1") as Gtk.ComboBox;
        var map_source_factory = Champlain.MapSourceFactory.dup_default();

        var liststore = new Gtk.ListStore (MS_Column.N_COLUMNS, typeof (string), typeof (string));

        foreach (unowned MapSource s0 in msources)
        {
            s0.desc = new  MwpMapSource(
                s0.id,
                s0.name,
                s0.licence,
                s0.licence_uri,
                s0.min_zoom,
                s0.max_zoom,
                s0.tile_size,
                0, // Champlain.MapProjection.MERCATOR,
                s0.uri_format);
            map_source_factory.register((Champlain.MapSourceDesc)s0.desc);
        }

        var sources =  map_source_factory.get_registered();
        int i = 0;
        int defval = 0;
        string? defsource = null;

        foreach (Champlain.MapSourceDesc s in sources)
        {
            var name = s.get_name();
            if(name.contains("OpenWeatherMap"))
                continue;

            TreeIter iter;
            liststore.append(out iter);
            var id = s.get_id();
            liststore.set (iter, MS_Column.ID, id);

            if(name.contains("OpenStreetMap"))
                name = name.replace("OpenStreetMap","OSM");

            liststore.set (iter, MS_Column.NAME, name);
            if (defmap != null && name == defmap)
            {
                defval = i;
                defsource = id;
            }
            i++;
        }
        combo.set_model(liststore);
        if(defsource != null)
        {
            var src = map_source_factory.create_cached_source(defsource);
            view.set_property("map-source", src);
        }

        var cell = new Gtk.CellRendererText();
        combo.pack_start(cell, false);

        combo.add_attribute(cell, "text", 1);
        combo.set_active(defval);
        combo.changed.connect (() => {
                GLib.Value val1;
                TreeIter iter;
                combo.get_active_iter (out iter);
                liststore.get_value (iter, 0, out val1);
                var source = map_source_factory.create_cached_source((string)val1);
                var zval = zoomer.adjustment.value;
                var cx = lx;
                var cy = ly;
                view.set_property("map-source", source);

                    /* Stop oob zooms messing up the map */
                var mmax = view.get_max_zoom_level();
                var mmin = view.get_min_zoom_level();
                var chg = false;
                if (zval > mmax)
                {
                    chg = true;
                    view.set_property("zoom-level", mmax);
                }
                if (zval < mmin)
                {
                    chg = true;
                    view.set_property("zoom-level", mmin);
                }
                if (chg == true)
                {
                    view.center_on(cy, cx);
                }
            });

    }

    public Mission get_mission_data()
    {
        Mission m = ls.to_mission();
        ls.calc_mission_dist(out m.dist, out m.lt, out m.et);
        m.nspeed = ls.get_mission_speed();
        if (conf.compat_vers != null)
            m.version = conf.compat_vers;
        return m;
    }

    public void on_file_save()
    {
        if (last_file == null)
        {
            on_file_save_as ();
        }
        else
        {
            var m = get_mission_data();
            m.to_xml_file(last_file);
            update_title_from_file(last_file);
        }
        get_mission_pix();
    }

    private string get_cached_mission_image(string mfn)
    {
        var cached = GLib.Path.build_filename(Environment.get_user_cache_dir(),
                                              "mwp");
        try
        {
            var dir = File.new_for_path(cached);
            dir.make_directory_with_parents ();
        } catch {}
        var chk = Checksum.compute_for_string(ChecksumType.MD5, mfn);
        StringBuilder sb = new StringBuilder();
        sb.append(chk);
        sb.append(".png");
        return GLib.Path.build_filename(cached,sb.str);
    }

    private void get_mission_pix()
    {
        if(last_file != null)
        {
            var wdw = embed.get_window();
            var w = wdw.get_width();
            var h = wdw.get_height();
            try
            {
                var pixb = Gdk.pixbuf_get_from_window (wdw, 0, 0, w, h);
                var path = get_cached_mission_image(last_file);
                int dw,dh;
                if(w > h)
                {
                    dw = 256;
                    dh = 256* h / w;
                }
                else
                {
                    dh = 256;
                    dw = 256* w / h;
                }
                var spixb = pixb.scale_simple(dw, dh, Gdk.InterpType.BILINEAR);
                spixb.save(path, "png");
            } catch (Error e) {
                MWPLog.message ("pix: %s\n", e.message);
            }
        }
    }

    public void on_file_save_as ()
    {
        Gtk.FileChooserDialog chooser = new Gtk.FileChooserDialog (
            "Select a mission file", null, Gtk.FileChooserAction.SAVE,
            "_Cancel",
            Gtk.ResponseType.CANCEL,
            "_Save",
            Gtk.ResponseType.ACCEPT);
        chooser.set_transient_for(window);
        chooser.select_multiple = false;
        Gtk.FileFilter filter = new Gtk.FileFilter ();
        if(conf.missionpath != null)
            chooser.set_current_folder (conf.missionpath);

        filter.set_filter_name ("Mission");
        filter.add_pattern ("*.mission");
        filter.add_pattern ("*.xml");
//            filter.add_pattern ("*.json");
        chooser.add_filter (filter);

        filter = new Gtk.FileFilter ();
        filter.set_filter_name ("All Files");
        filter.add_pattern ("*");
        chooser.add_filter (filter);

            // Process response:
        if (chooser.run () == Gtk.ResponseType.ACCEPT) {
            last_file = chooser.get_filename ();
            if(!(last_file.has_suffix(".mission") ||
                 last_file.has_suffix(".xml")))
                last_file += ".mission";
            var m = get_mission_data();
            m.to_xml_file(last_file);
            update_title_from_file(last_file);
        }
        chooser.close ();
    }

    private void update_title_from_file(string fname)
    {
        var basename = GLib.Path.get_basename(fname);
        window.title = @"mwp = $basename";
    }

    private uint guess_appropriate_zoom(Mission ms)
    {
            // Formula from:
            // http://wiki.openstreetmap.org/wiki/Zoom_levels
            //
        double cse,m_width,m_height;
        const double erad = 6372.7982; // earth radius
        const double ecirc = erad*Math.PI*2.0; // circumference
        const double rad = 0.017453292; // deg to rad

        Geo.csedist(ms.cy, ms.minx, ms.cy, ms.maxx, out m_width, out cse);
        Geo.csedist(ms.miny, ms.cx, ms.maxy, ms.cx, out m_height, out cse);
        m_width = m_width * 1852;
        m_height = m_height * 1852;

//        Gdk.Screen scn = Gdk.Screen.get_default();
//        double dpi = scn.get_resolution(); // in case we need it ...
        uint z;
        for(z = view.get_max_zoom_level();
            z >= view.get_min_zoom_level(); z--)
        {
            double s = 1000 * ecirc * Math.cos(ms.cy * rad) / (Math.pow(2,(z+8)));
            if(s*conf.window_w > m_width && s*conf.window_h > m_height)
                break;
        }
        return z;
    }

    private void load_file(string fname, bool have_preview=false)
    {
        var ms = new Mission ();
        if(ms.read_xml_file (fname) == true)
        {
            validatelab.set_text("");
            ms.dump();
            ls.import_mission(ms);
            var mmax = view.get_max_zoom_level();
            var mmin = view.get_min_zoom_level();
            view.center_on(ms.cy, ms.cx);
            if(ms.zoom == -1)
                ms.zoom = guess_appropriate_zoom(ms);

            if (ms.zoom < mmin)
                ms.zoom = mmin;

            if (ms.zoom > mmax)
                ms.zoom = mmax;

            view.set_property("zoom-level", ms.zoom);
            markers.add_list_store(ls);
            last_file = fname;
            update_title_from_file(fname);
            if(have_home && ls.have_rth)
                markers.add_rth_point(home_pos.lat,home_pos.lon,ls);
            need_preview = true;
        }
        else
        {
            mwp_warning_box("Failed to open file");
        }
    }

    private void mwp_warning_box(string warnmsg,
                                 Gtk.MessageType klass=Gtk.MessageType.WARNING,
                                 int timeout = 0)
    {
        var msg = new Gtk.MessageDialog.with_markup (window,
                                                     0,
                                                     klass,
                                                     Gtk.ButtonsType.OK,
                                                     warnmsg);
        if(timeout > 0)
        {
            Timeout.add_seconds(timeout, () => {
                    msg.destroy();
                    return Source.CONTINUE;
                });
        }
        msg.response.connect ((response_id) => {
                msg.destroy();
            });
        msg.show();
    }

    public void on_file_open ()
    {
        bool have_preview = false;
        Gtk.FileChooserDialog chooser = new Gtk.FileChooserDialog (
            "Select a mission file", null, Gtk.FileChooserAction.OPEN,
            "_Cancel",
            Gtk.ResponseType.CANCEL,
            "_Open",
            Gtk.ResponseType.ACCEPT);
        chooser.select_multiple = false;
        if(conf.missionpath != null)
            chooser.set_current_folder (conf.missionpath);

        chooser.set_transient_for(window);
        Gtk.FileFilter filter = new Gtk.FileFilter ();
	filter.set_filter_name ("Mission");
	filter.add_pattern ("*.mission");
	filter.add_pattern ("*.xml");
//	filter.add_pattern ("*.json");
	chooser.add_filter (filter);

	filter = new Gtk.FileFilter ();
	filter.set_filter_name ("All Files");
	filter.add_pattern ("*");
	chooser.add_filter (filter);

        var prebox = new Gtk.Box(Gtk.Orientation.VERTICAL, 2);
        var preview = new Gtk.Image();
        var plabel = new Gtk.Label (null);
        prebox.pack_start (preview, false, false, 1);
        prebox.pack_start (plabel, false, false, 1);

        chooser.set_preview_widget(prebox);
        chooser.update_preview.connect (() => {
                string uri = chooser.get_preview_uri ();
                have_preview = false;
                Gdk.Pixbuf pixbuf = null;
                if (uri != null && uri.has_prefix ("file://") == true)
                {
                    var fn = uri.substring (7);
                    if(!FileUtils.test (fn, FileTest.IS_DIR))
                    {
                        var m = new Mission ();
                        if(m.read_xml_file (fn) == true)
                        {
                            var sb = new StringBuilder();
                            sb.append("Points: %u\n".printf(m.npoints));
                            sb.append("Distance: %.1fm\n".printf(m.dist));
                            sb.append("Flight time %ds\n".printf(m.et));
                            if(m.lt != -1)
                                sb.append("Loiter time: %ds\n".printf(m.lt));
                            if(m.nspeed == 0 && m.dist > 0 && m.et > 0)
                                m.nspeed = m.dist / (m.et - 3*m.npoints);
                            sb.append("Speed: %.1f m/s\n".printf(m.nspeed));
                            if(m.maxalt != 0x80000000)
                                sb.append("Max altitude: %dm\n".printf(m.maxalt));
                            plabel.set_text(sb.str);
                        }
                        else
                            plabel.set_text("");

                        var ifn = get_cached_mission_image(fn);
                        try
                        {
                            pixbuf = new Gdk.Pixbuf.from_file_at_scale (ifn, 256,
                                                                        256, true);
                            if(pixbuf != null)
                                have_preview = true;
                        }
                        catch {
                            if (FileUtils.test (fn, FileTest.EXISTS))
                            pixbuf = FlatEarth.getpixbuf(fn, 256, 256);
                        }
                    }
                }

                if(pixbuf != null)
                {
                    preview.set_from_pixbuf(pixbuf);
                    prebox.show_all ();
                }
                else
                    prebox.hide ();
            });

            // Process response:
        if (chooser.run () == Gtk.ResponseType.ACCEPT) {
            ls.clear_mission();
            var fn = chooser.get_filename ();
            chooser.close ();
            load_file(fn, have_preview);
        }
        else
            chooser.close ();
    }

    private void replay_log(bool delay=true)
    {
        if(thr != null)
        {
            robj.stop();
            duration = -1;
        }
        else
        {
            Gtk.FileChooserDialog chooser = new Gtk.FileChooserDialog (
            "Select a log file", null, Gtk.FileChooserAction.OPEN,
            "_Cancel",
            Gtk.ResponseType.CANCEL,
            "_Open",
            Gtk.ResponseType.ACCEPT);
            chooser.select_multiple = false;
            chooser.set_transient_for(window);
            Gtk.FileFilter filter = new Gtk.FileFilter ();
            filter.set_filter_name ("Log");
            filter.add_pattern ("*.log");
            chooser.add_filter (filter);
            if(conf.logpath != null)
                chooser.set_current_folder (conf.logpath);

            filter = new Gtk.FileFilter ();
            filter.set_filter_name ("All Files");
            filter.add_pattern ("*");
            chooser.add_filter (filter);

            var res = chooser.run ();

                // Process response:
            if ( res == Gtk.ResponseType.ACCEPT) {
                var fn = chooser.get_filename ();
                chooser.close ();
                usemag = force_mag;
                run_replay(fn, delay, Player.MWP);
            }
            else
                chooser.close ();
        }
    }

    private void cleanup_replay()
    {
        MWPLog.message("============== Replay complete ====================\n");
        if (replayer == Player.MWP)
        {
            thr.join();
            thr = null;
        }
        saved_menuitem.label = saved_menutext;

        menureplay.sensitive = menuloadlog.sensitive =
            menubblog.sensitive = menubbload.sensitive = true;

        Posix.close(playfd[0]);
        Posix.close(playfd[1]);
        if (conf.audioarmed == true)
            audio_cb.active = false;
        conf.logarmed = xlog;
        conf.audioarmed = xaudio;
        duration = -1;
        armtime = 0;
        armed_spinner.stop();
        armed_spinner.hide();
        conbutton.sensitive = true;
        armed = larmed = 0;
        replay_paused = false;
        window.title = "mwp";
    }

    private void run_replay(string fn, bool delay, Player rtype,
                            int idx=0, int btype=0, bool force_gps=false)
    {
        xlog = conf.logarmed;
        xaudio = conf.audioarmed;

        playfd = new int[2];
        var sr = cf_pipe(playfd);

        if(sr == 0)
        {
            replay_paused = false;
            MWPLog.message("Replay \"%s\" log %s\n",
                           (rtype == 2) ? "bbox" : "mwp",
                           fn);
            if(craft != null)
                craft.park();

            init_have_home();
            conf.logarmed = false;
            if(delay == false)
                conf.audioarmed = false;

            if(msp.available)
                serial_doom(conbutton);

            init_state();
            conbutton.sensitive = false;
            update_title_from_file(fn);
            replayer = rtype;
            msp.open_fd(playfd[0],-1, true);
            menureplay.sensitive = menuloadlog.sensitive =
                menubblog.sensitive = menubbload.sensitive = false;
            switch(replayer)
            {
                case Player.MWP:
                    robj = new ReplayThread();
                    robj.replay_mission_file.connect((mf) => {
                            load_file(mf);
                        });
                    thr = robj.run(playfd[1], fn, delay);
                    saved_menuitem = (delay) ? menureplay : menuloadlog;
                    break;
                case Player.BBOX:
                    spawn_bbox_task(fn, idx, btype, delay, force_gps);
                    saved_menuitem = (delay) ? menubblog : menubbload;
                    break;
            }
            saved_menutext = saved_menuitem.label;
            saved_menuitem.label = "Stop Replay";
            saved_menuitem.sensitive = true;
        }
    }

    private void spawn_bbox_task(string fn, int index, int btype,
                                 bool delay, bool force_gps)
    {
        string [] args = {"replay_bbox_ltm.rb",
                          "--fd", "%d".printf(playfd[1]),
                          "-i", "%d".printf(index),
                          "-t", "%d".printf(btype)};
        if(delay == false)
            args += "-f";
        if(force_gps)
            args += "-g";

        args += fn;
        args += null;

        MWPLog.message("%s\n", string.joinv(" ",args));
        try {
            Process.spawn_async_with_pipes (null, args, null,
                                            SpawnFlags.SEARCH_PATH |
                                            SpawnFlags.LEAVE_DESCRIPTORS_OPEN |
                                            SpawnFlags.STDOUT_TO_DEV_NULL |
                                            SpawnFlags.STDERR_TO_DEV_NULL |
                                            SpawnFlags.DO_NOT_REAP_CHILD,
                                            (() => {
                                                for(var i = 3; i < 512; i++)
                                                {
                                                    if(i != playfd[1])
                                                        Posix.close(i);
                                                }
                                            }),
                                            out child_pid,
                                            null, null, null);
            ChildWatch.add (child_pid, (pid, status) => {
                    MWPLog.message("Close child pid %u, %u\n",
                                   pid, Process.exit_status(status));
                    Process.close_pid (pid);
                    cleanup_replay();
                });
        } catch (SpawnError e) {
            MWPLog.message("spawnerror: %s\n", e.message);
        }
    }

    private void replay_bbox (bool delay, string? fn = null)
    {
        if(replayer == Player.BBOX)
        {
            Posix.kill(child_pid, Posix.SIGTERM);
        }
        else
        {
            var id = bb_runner.run(fn);
            if(id == 1001)
            {
                string bblog;
                int index;
                int btype;
                bool force_gps;

                bb_runner.get_result(out bblog, out index, out btype, out force_gps);
                run_replay(bblog, delay, Player.BBOX, index, btype, force_gps);
            }
        }
    }

    private void download_mission()
    {
        xdopoll = dopoll;
        dopoll = false;
        wp_resp= {};
        wpmgr.wp_flag = WPDL.REPLACE;
        Timeout.add(250, () => {
                start_wp_timer(30*1000);
                request_wp(1);
                return false;
            });
    }

    public static void xchild()
    {
        JsonMapDef.killall();
        if(Logger.is_logging)
            Logger.stop();
    }

    private static string read_cmd_opts()
    {
        var sb = new StringBuilder ();
        var fn = MWPUtils.find_conf_file("cmdopts");
        if(fn != null)
        {
            var file = File.new_for_path(fn);
            try {
                var dis = new DataInputStream(file.read());
                string line;
                while ((line = dis.read_line (null)) != null)
                {
                    if(line.strip().length > 0 &&
                       !line.has_prefix("#") &&
                       !line.has_prefix(";"))
                    {
                        sb.append(line);
                        sb.append(" ");
                    }
                }
            } catch (Error e) {
                error ("%s", e.message);
            }
        }
        return sb.str;
    }

    private static void check_env_args(OptionContext opt)
    {
        var s1 = read_cmd_opts();
        var s2 = Environment.get_variable("MWP_ARGS");
        var sb = new StringBuilder();
        if(s1.length > 0)
           sb.append(s1);
        if(s2 != null)
            sb.append(s2);
        if(sb.str.length > 0)
        {
            MWPLog.message("prepending %s\n", sb.str);
            sb.prepend("mwp ");
            string []m;
            try
            {
                Shell.parse_argv(sb.str, out m);
                unowned string? []om = m;
                opt.parse(ref om);
            } catch {}
        }
    }

    public static int main (string[] args)
    {
        time_t currtime;
        time_t(out currtime);

        if (GtkClutter.init (ref args) != InitError.SUCCESS)
            return 1;

        if(Posix.isatty(stderr.fileno()) == false)
        {
            var fn = "mwp_stderr_%s.txt".printf(Time.local(currtime).format("%F"));
            stderr = FileStream.open(fn,"a");
        }
        MWPLog.message("mwp startup version: %s\n", mwpvers);
        var opt = new OptionContext("");
        try {
            opt.set_help_enabled(true);
            opt.add_main_entries(options, null);
            check_env_args(opt);
            opt.parse(ref args);
        } catch (OptionError e) {
            stderr.printf("Error: %s\n", e.message);
            stderr.printf("Run '%s --help' to see a full list of available "+
                          "options\n", args[0]);
            return 1;
        }
        Gst.init (ref args);
        atexit(MWPlanner.xchild);
        var app = new MWPlanner();
        app.run ();
        app.cleanup();
        return 0;
    }
}
