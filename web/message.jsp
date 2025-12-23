<%@ page contentType="text/html;charset=UTF-8" language="java" %>
<%@ page import="java.io.*" %>
<%@ page import="java.nio.charset.StandardCharsets" %>
<%@ page import="java.nio.file.*" %>
<%@ page import="java.util.UUID" %>
<%@ page import="java.util.Set" %>
<%@ page import="java.util.HashSet" %>
<%@ page import="java.util.Arrays" %>

<%!
    // HTML 转义：防反射型 XSS (保持原样，这部分不仅没问题，而且是必须的)
    private static String escapeHtml(String s) {
        if (s == null) return "";
        return s.replace("&", "&amp;")
                .replace("<", "&lt;")
                .replace(">", "&gt;")
                .replace("\"", "&quot;")
                .replace("'", "&#x27;");
    }

    // 提取扩展名（小写），没有则返回空串
    private static String extLower(String name) {
        if (name == null) return "";
        int dot = name.lastIndexOf('.');
        if (dot < 0 || dot == name.length() - 1) return "";
        return name.substring(dot + 1).toLowerCase();
    }

    // [安全修复] 关键修改：改用“白名单”策略
    // 只有在列表里的后缀才允许上传。这彻底防御了 .html/.svg (XSS) 和 .jsp/.php (RCE)。
    private static boolean isAllowedExt(String name) {
        if (name == null) return false;
        String ext = extLower(name);

        // 定义允许的后缀列表 (根据你的业务需求增减)
        Set<String> allowList = new HashSet<>(Arrays.asList(
                "jpg", "jpeg", "png", "gif", "bmp", "webp", // 图片
                "pdf", "txt"                                // 文档
                // 注意：绝对不要加 "html", "htm", "svg", "xml"
        ));

        return allowList.contains(ext);
    }

    // 把文件名清理成“安全可用”的名字：保留字母/数字/._-，其他替换为 _
    private static String sanitizeFileName(String baseName) {
        if (baseName == null) return "file";
        // 允许各种语言的字母/数字：\p{L}\p{N}
        String cleaned = baseName.replaceAll("[^\\p{L}\\p{N}._-]", "_");
        // 避免太长
        if (cleaned.length() > 150) cleaned = cleaned.substring(0, 150);
        if (cleaned.isBlank()) cleaned = "file";
        return cleaned;
    }
%>

<html>
<head>
    <title>Upload</title>
</head>
<body>
<%
    // ===== 1) 基础校验：必须是 multipart =====
    String contentType = request.getContentType();
    if (contentType == null || !contentType.contains("multipart/form-data")) {
        out.print("请用 multipart/form-data 上传文件");
        return;
    }

    // ===== 2) 限制大小 =====
    final int MAX_SIZE = 10 * 1024 * 1024; // 10MB
    int formDataLength = request.getContentLength();
    if (formDataLength < 0) {
        out.print("无法获取上传大小（缺少 Content-Length）");
        return;
    }
    if (formDataLength > MAX_SIZE) {
        out.print("上传大小不能超过 " + MAX_SIZE + " 字节");
        return;
    }

    // ===== 3) 读完整个请求体 =====
    byte[] dataBytes = new byte[formDataLength];
    try (DataInputStream in = new DataInputStream(request.getInputStream())) {
        int total = 0;
        while (total < formDataLength) {
            int read = in.read(dataBytes, total, formDataLength - total);
            if (read == -1) break;
            total += read;
        }
        if (total != formDataLength) {
            out.print("读取上传数据失败");
            return;
        }
    }

    // ===== 4) 解析 multipart =====
    String body = new String(dataBytes, StandardCharsets.ISO_8859_1);

    // 4.1 取 boundary
    String boundary = null;
    int bIdx = contentType.indexOf("boundary=");
    if (bIdx >= 0) {
        boundary = contentType.substring(bIdx + "boundary=".length()).trim();
        if (boundary.startsWith("\"") && boundary.endsWith("\"") && boundary.length() >= 2) {
            boundary = boundary.substring(1, boundary.length() - 1);
        }
    }
    if (boundary == null || boundary.isBlank()) {
        out.print("无法解析 boundary");
        return;
    }

    // 4.2 解析 filename="..."
    int fnKey = body.indexOf("filename=\"");
    if (fnKey < 0) {
        out.print("未找到 filename 字段");
        return;
    }
    int fnStart = fnKey + "filename=\"".length();
    int fnEnd = body.indexOf("\"", fnStart);
    if (fnEnd < 0) {
        out.print("filename 解析失败");
        return;
    }

    String rawFileName = body.substring(fnStart, fnEnd);

    // ===== 5) 文件名处理 =====
    // 只取 basename
    int lastSlash = Math.max(rawFileName.lastIndexOf('/'), rawFileName.lastIndexOf('\\'));
    String baseName = (lastSlash >= 0) ? rawFileName.substring(lastSlash + 1) : rawFileName;
    baseName = baseName.replace("\r", "").replace("\n", "").trim();

    if (baseName.isBlank()) {
        out.print("非法文件名");
        return;
    }

    // [安全修复] 这里不再调用 isForbiddenExt，而是调用 isAllowedExt
    if (!isAllowedExt(baseName)) {
        // 这一步拦截了所有非白名单后缀（包括 .html）
        out.print("不支持的文件类型，仅允许上传图片、PDF或TXT文件。<br/>文件名：" + escapeHtml(baseName));
        return;
    }

    // 文件名清理
    String safeBaseName = sanitizeFileName(baseName);

    // ===== 6) 生成服务端文件名 =====
    String ext = extLower(safeBaseName);
    // 使用 UUID 避免覆盖
    String serverName = UUID.randomUUID().toString() + (ext.isEmpty() ? "" : "." + ext);

    // ===== 7) 上传目录 =====
    String uploadReal = application.getRealPath("/upload");
    if (uploadReal == null) {
        out.print("无法定位 upload 目录");
        return;
    }
    Path baseDir = Paths.get(uploadReal).toAbsolutePath().normalize();
    Files.createDirectories(baseDir);
    baseDir = baseDir.toRealPath();

    // ===== 8) 路径沙箱 check (CWE-23) =====
    Path target = baseDir.resolve(serverName).normalize();
    if (!target.startsWith(baseDir)) {
        out.print("非法路径，拒绝上传");
        return;
    }

    // ===== 9) 计算内容起止位置 =====
    int headerEnd = body.indexOf("\r\n\r\n", fnEnd);
    int headerLen = 4;
    if (headerEnd < 0) {
        headerEnd = body.indexOf("\n\n", fnEnd);
        headerLen = 2;
    }
    if (headerEnd < 0) {
        out.print("无法定位文件内容开始位置");
        return;
    }
    int startPos = headerEnd + headerLen;

    String boundaryMarker = "\r\n--" + boundary;
    int boundaryPos = body.indexOf(boundaryMarker, startPos);
    if (boundaryPos < 0) {
        boundaryMarker = "\n--" + boundary;
        boundaryPos = body.indexOf(boundaryMarker, startPos);
    }
    if (boundaryPos < 0) {
        out.print("无法定位文件内容结束位置");
        return;
    }
    int endPos = boundaryPos;

    if (endPos <= startPos || endPos > dataBytes.length) {
        out.print("文件内容范围计算失败");
        return;
    }

    // ===== 10) 写文件 =====
    try (OutputStream os = Files.newOutputStream(target, StandardOpenOption.CREATE_NEW)) {
        os.write(dataBytes, startPos, endPos - startPos);
    }

    // ===== 11) 输出结果 (输出编码 CWE-79) =====
    // 即使这里有 escapeHtml，如果允许上传 html 文件，用户访问文件链接时仍会触发 XSS。
    // 但现在我们加上了白名单限制，所以这里是安全的。
    out.print("<b>文件上传成功</b><br/>");
    out.print("原始文件名：" + escapeHtml(baseName) + "<br/>");
    out.print("保存文件名：" + escapeHtml(serverName));
%>
</body>
</html>