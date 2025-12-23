package web.servlet.file;

import javax.servlet.ServletException;
import javax.servlet.annotation.WebServlet;
import javax.servlet.http.*;
import java.io.IOException;
import java.nio.file.*;

@WebServlet("/deleteFileServlet")
public class DeleteFileServlet extends HttpServlet {

    @Override
    protected void doPost(HttpServletRequest request, HttpServletResponse response)
            throws ServletException, IOException {

        request.setCharacterEncoding("utf-8");
        String fileName = request.getParameter("filename");

        if (fileName == null || fileName.isBlank()) {
            response.sendError(HttpServletResponse.SC_BAD_REQUEST, "filename is required");
            return;
        }

        // 1) 固定允许范围：upload 目录（沙箱根目录）
        String uploadPath = getServletContext().getRealPath("upload");
        if (uploadPath == null) {
            response.sendError(HttpServletResponse.SC_INTERNAL_SERVER_ERROR, "upload path is not available");
            return;
        }

        Path baseDir = Paths.get(uploadPath).toRealPath();

        // 2) 计算目标路径：拼接(resolve) + 规范化（把 ../ 折叠出来）(normalize)
        Path target = baseDir.resolve(fileName).normalize();

        // 3) 核心校验：必须仍在 upload 目录内
        if (!target.startsWith(baseDir)) {
            response.sendError(HttpServletResponse.SC_BAD_REQUEST, "invalid filename");
            return;
        }

        // 4) 只删除普通文件（不删目录；检查时不跟随软链）
        if (Files.exists(target) && Files.isRegularFile(target, LinkOption.NOFOLLOW_LINKS)) {
            Files.delete(target);
        }

        request.getRequestDispatcher("/fileListServlet").forward(request, response);
    }

    @Override
    protected void doGet(HttpServletRequest request, HttpServletResponse response)
            throws ServletException, IOException {
        doPost(request, response);
    }
}
