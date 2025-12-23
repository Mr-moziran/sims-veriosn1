package web.servlet.file;

import domain.Admin;
import domain.Student;
import domain.Teacher;

import javax.servlet.ServletException;
import javax.servlet.ServletOutputStream;
import javax.servlet.annotation.WebServlet;
import javax.servlet.http.*;
import java.io.IOException;
import java.io.InputStream;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;

@WebServlet("/downloadServlet")
public class DownloadServlet extends HttpServlet {

    protected void doPost(HttpServletRequest request, HttpServletResponse response) throws ServletException, IOException {

        // ===== FIX 1：先做会话/角色校验（避免未授权先下载）=====
        HttpSession session = request.getSession(false);
        Student student = session == null ? null : (Student) session.getAttribute("student");
        Admin admin = session == null ? null : (Admin) session.getAttribute("admin");
        Teacher teacher = session == null ? null : (Teacher) session.getAttribute("teacher");

        int roleCount = 0;
        if (student != null) roleCount++;
        if (admin != null) roleCount++;
        if (teacher != null) roleCount++;
        if (roleCount != 1) {
            request.getRequestDispatcher("error.jsp").forward(request, response);
            return;
        }

        String filename = request.getParameter("filename");

        // ===== FIX 2：filename 非空 + 防路径穿越 + 防 CRLF 响应头注入 =====
        if (filename == null) {
            request.getRequestDispatcher("error.jsp").forward(request, response);
            return;
        }
        filename = filename.trim();
        if (filename.isEmpty() || filename.length() > 255) {
            request.getRequestDispatcher("error.jsp").forward(request, response);
            return;
        }
        // 禁止控制字符/CRLF（防 Header Injection / Response Splitting）
        for (int i = 0; i < filename.length(); i++) {
            char c = filename.charAt(i);
            if (c == '\r' || c == '\n' || c <= 0x1F || c == 0x7F) {
                request.getRequestDispatcher("error.jsp").forward(request, response);
                return;
            }
        }
        // 禁止路径分隔符和 ..（防路径穿越）
        if (filename.contains("/") || filename.contains("\\") || filename.contains("..")) {
            request.getRequestDispatcher("error.jsp").forward(request, response);
            return;
        }

        // ===== FIX 3：响应头更规范 + 防嗅探 + Content-Disposition 使用 filename* =====
        response.setContentType("application/octet-stream");                 // 原来 addHeader content-Type
        response.setHeader("X-Content-Type-Options", "nosniff");            // 防止浏览器嗅探当 HTML 执行

        // 用 RFC 5987 的 filename*，避免直接拼接原始输入到 header（也支持中文）
        String encoded = URLEncoder.encode(filename, StandardCharsets.UTF_8).replace("+", "%20");
        response.setHeader("Content-Disposition", "attachment; filename*=UTF-8''" + encoded);

        // ===== 原有下载逻辑（加了 in==null 防 NPE；用 try-with-resources 更稳）=====
        try (InputStream in = getServletContext().getResourceAsStream("/upload/" + filename)) {
            if (in == null) {
                request.getRequestDispatcher("error.jsp").forward(request, response);
                return;
            }

            try (ServletOutputStream out = response.getOutputStream()) {
                byte[] bs = new byte[1024];
                int len;
                while ((len = in.read(bs)) != -1) {
                    out.write(bs, 0, len);
                }
                out.flush();
            }
        }

        // ===== FIX 4：写完下载流就结束，不要再 forward 到 JSP（响应已用于下载）=====
        return;
    }

    protected void doGet(HttpServletRequest request, HttpServletResponse response) throws ServletException, IOException {
        doPost(request, response);
    }
}
