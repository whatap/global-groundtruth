import com.sun.net.httpserver.*; import java.net.*; import java.io.*;
public class Main { public static void main(String[] a) throws Exception {
  HttpServer s = HttpServer.create(new InetSocketAddress(8080), 0);
  s.createContext("/", x -> { byte[] b = "hello\n".getBytes(); x.sendResponseHeaders(200, b.length); try (OutputStream o = x.getResponseBody()) { o.write(b); } });
  s.start(); } }
