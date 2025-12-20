package web.servlet.file;

import domain.Photo;
import domain.Student;
import domain.Teacher;
import service.PhotoService;
import service.impl.PhotoServiceImpl;

import javax.servlet.ServletException;
import javax.servlet.annotation.WebServlet;
import javax.servlet.http.HttpServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;
import javax.servlet.http.HttpSession;
import java.io.*;

@WebServlet("/showPhotoServlet")
public class ShowPhotoServlet extends HttpServlet {

    @Override
    protected void doPost(HttpServletRequest request, HttpServletResponse response) throws ServletException, IOException {

        request.setCharacterEncoding("utf-8");
        HttpSession session = request.getSession();

        Student student = (Student) session.getAttribute("student");
        Teacher teacher = (Teacher) session.getAttribute("teacher");

        PhotoService service = new PhotoServiceImpl();
        Photo p;

        if (student != null) {
            p = service.findPhotoByPhotoId(student.getS_id());
        } else {
            p = service.findPhotoByPhotoId(teacher.getT_id());
        }

        String imagePath;
        if (p == null) {
            imagePath = getServletContext().getRealPath("/photos/") + "0.jpg";
        } else {
            imagePath = getServletContext().getRealPath("/photos/") + p.getPhotoName();
        }

        response.reset();

        // 根据后缀设置 Content-Type（图片不需要 charset）
        String lower = imagePath.toLowerCase();
        if (lower.endsWith(".jpg") || lower.endsWith(".jpeg")) {
            response.setContentType("image/jpeg");
        } else if (lower.endsWith(".gif")) {
            response.setContentType("image/gif");
        } else if (lower.endsWith(".png")) {
            response.setContentType("image/png");
        } else {
            response.setContentType("application/octet-stream");
        }

        // 直接把文件流写到响应输出流
        try (InputStream in = new FileInputStream(imagePath);
             OutputStream out = response.getOutputStream()) {

            byte[] buf = new byte[8192];
            int len;
            while ((len = in.read(buf)) != -1) {
                out.write(buf, 0, len);
            }
            out.flush();
        }
    }

    @Override
    protected void doGet(HttpServletRequest request, HttpServletResponse response) throws ServletException, IOException {
        doPost(request, response);
    }
}
