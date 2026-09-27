// Tiny JVM payloads for the java-zoo lab image. Java 7 syntax, so the same
// class file runs on every JDK in the image (7 .. 21).
//   Zoo sleep                    keep a JVM alive and idle
//   Zoo hold PORT...             accept on each port and drain every session
//                                (stands in for the collection server)
//   Zoo sess HOST PORT:N...      open N TCP sessions to HOST:PORT (for each
//                                PORT:N) and hold them
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.nio.channels.SelectionKey;
import java.nio.channels.Selector;
import java.nio.channels.ServerSocketChannel;
import java.nio.channels.SocketChannel;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;

public class Zoo {
    public static void main(String[] a) throws Exception {
        String mode = a.length > 0 ? a[0] : "sleep";
        if (mode.equals("hold")) hold(a);
        else if (mode.equals("sess")) sess(a);
        else for (;;) Thread.sleep(3600000L);
    }

    static void hold(String[] a) throws Exception {
        Selector sel = Selector.open();
        for (int i = 1; i < a.length; i++) {
            ServerSocketChannel s = ServerSocketChannel.open();
            s.socket().setReuseAddress(true);
            s.socket().bind(new InetSocketAddress("127.0.0.1", Integer.parseInt(a[i])), 512);
            s.configureBlocking(false);
            s.register(sel, SelectionKey.OP_ACCEPT);
        }
        ByteBuffer buf = ByteBuffer.allocate(16384);
        for (;;) {
            sel.select();
            Iterator<SelectionKey> it = sel.selectedKeys().iterator();
            while (it.hasNext()) {
                SelectionKey k = it.next();
                it.remove();
                try {
                    if (k.isAcceptable()) {
                        SocketChannel c = ((ServerSocketChannel) k.channel()).accept();
                        if (c != null) { c.configureBlocking(false); c.register(sel, SelectionKey.OP_READ); }
                    } else if (k.isReadable()) {
                        buf.clear();
                        if (((SocketChannel) k.channel()).read(buf) < 0) { k.cancel(); k.channel().close(); }
                    }
                } catch (Exception e) { k.cancel(); try { k.channel().close(); } catch (Exception ignored) { } }
            }
        }
    }

    static void sess(String[] a) throws Exception {
        List<Socket> held = new ArrayList<Socket>();
        for (int i = 2; i < a.length; i++) {
            int port = Integer.parseInt(a[i].split(":")[0]), n = Integer.parseInt(a[i].split(":")[1]);
            for (int k = 0; k < n; ) {
                try { held.add(new Socket(a[1], port)); k++; } catch (Exception e) { Thread.sleep(1000L); }
            }
        }
        for (;;) Thread.sleep(3600000L);
    }
}
