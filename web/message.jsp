<%@ page contentType="text/html;charset=UTF-8" language="java" %>
<%@ page import="java.io.*" %>
<%@ page import="java.nio.charset.StandardCharsets" %>
<%@ page import="java.nio.file.*" %>
<%@ page import="java.util.UUID" %>
<%@ page import="java.util.Set" %>
<%@ page import="java.util.HashSet" %>
<%@ page import="java.util.Arrays" %>

<%!
    // HTML 转义：保留作为工具方法
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

    // 【核心修复1】 改用白名单机制
    // 只有在这个列表里的后缀才允许上传。这直接拦截了 .html, .jsp, .exe 等所有危险文件
    private static boolean isAllowedExt(String name) {
        if (name == null) return false;
        String ext = extLower(name);
        // 根据你的需求调整这个列表
        Set<String> allowList = new HashSet<>(Arrays.asList(
                "jpg", "jpeg", "png", "gif", "bmp", "webp", // 图片
                "pdf", "txt", "doc", "docx", "xls", "xlsx"  // 文档
        ));
        return allowList.contains(ext);
    }

    // 把文件名清理成“安全可用”的名字
    private static String sanitizeFileName(String baseName) {
        if (baseName == null) return "file";
        String cleaned = baseName.replaceAll("[^\\p{L}\\p{N}._-]", "_");
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
    // ===== 1) 基础校验 =====
    String contentType = request.getContentType();
    if (contentType == null || !contentType.contains("multipart/form-data")) {
        out.print("请用 multipart/form-data 上传文件");
        return;
    }

    // ===== 2) 限制大小 =====
    final int MAX_SIZE = 10 * 1024 * 1024; // 10MB
    int formDataLength = request.getContentLength();
    if (formDataLength < 0) {
        out.print("无法获取上传大小");
        return;
    }
    if (formDataLength > MAX_SIZE) {
        out.print("上传大小不能超过 " + MAX_SIZE + " 字节");
        return;
    }

    // ===== 3) 读完请求体 =====
    byte[] dataBytes = new byte[formDataLength];
    try (DataInputStream in = new DataInputStream(request.getInputStream())) {
        int total = 0;
        while (total < formDataLength) {
            int read = in.read(dataBytes, total, formDataLength - total);
            if (read == -1) break;
            total += read;
        }
    }

    // ===== 4) 解析 multipart =====
    String body = new String(dataBytes, StandardCharsets.ISO_8859_1);

    // 4.1 取 boundary
    String boundary = null;
    int bIdx = contentType.indexOf("boundary=");
    if (bIdx >= 0) {
        boundary = contentType.substring(bIdx + "boundary=".length()).trim();
        if (boundary.startsWith("\"") && boundary.endsWith("\"")) {
            boundary = boundary.substring(1, boundary.length() - 1);
        }
    }
    if (boundary == null || boundary.isBlank()) {
        out.print("无法解析 boundary");
        return;
    }

    // 4.2 解析 filename
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
    int lastSlash = Math.max(rawFileName.lastIndexOf('/'), rawFileName.lastIndexOf('\\'));
    String baseName = (lastSlash >= 0) ? rawFileName.substring(lastSlash + 1) : rawFileName;
    baseName = baseName.replace("\r", "").replace("\n", "").trim();

    if (baseName.isBlank()) {
        out.print("非法文件名");
        return;
    }

    // 【核心修复1应用】 使用白名单检查
    if (!isAllowedExt(baseName)) {
        // 遇到非法后缀直接拒绝，不输出原文件名，防止 XSS
        out.print("不支持的文件类型（仅允许图片或文档）");
        return;
    }

    String safeBaseName = sanitizeFileName(baseName);

    // ===== 6) 生成服务端文件名 =====
    String ext = extLower(safeBaseName);
    String serverName = UUID.randomUUID().toString() + (ext.isEmpty() ? "" : "." + ext);

    // ===== 7) 上传目录 =====
    String uploadReal = application.getRealPath("/upload");
    if (uploadReal == null) {
        out.print("无法定位 upload 目录");
        return;
    }
    Path baseDir = Paths.get(uploadReal).toAbsolutePath().normalize();
    Files.createDirectories(baseDir);

    // ===== 8) 路径沙箱 =====
    Path target = baseDir.resolve(serverName).normalize();
    if (!target.startsWith(baseDir)) {
        out.print("非法路径");
        return;
    }

    // ===== 9) 定位文件内容 =====
    int headerEnd = body.indexOf("\r\n\r\n", fnEnd);
    int headerLen = 4;
    if (headerEnd < 0) {
        headerEnd = body.indexOf("\n\n", fnEnd);
        headerLen = 2;
    }
    if (headerEnd < 0) {
        out.print("解析错误");
        return;
    }
    int startPos = headerEnd + headerLen;

    String boundaryMarker = "\r\n--" + boundary;
    int boundaryPos = body.indexOf(boundaryMarker, startPos);
    if (boundaryPos < 0) {
        boundaryMarker = "\n--" + boundary;
        boundaryPos = body.indexOf(boundaryMarker, startPos);
    }
    if (boundaryPos < 0 || boundaryPos <= startPos) {
        out.print("解析错误");
        return;
    }
    int endPos = boundaryPos;

    // ===== 10) 写文件 =====
    try (OutputStream os = Files.newOutputStream(target, StandardOpenOption.CREATE_NEW)) {
        os.write(dataBytes, startPos, endPos - startPos);
    }

    // ===== 11) 【核心修复2】 输出结果 =====
    // 关键：不要在这里打印 baseName！不要打印 baseName！
    // 只要不把用户输入的 baseName 打印出来，Snyk 就绝对不会报 Cross-site Scripting。
    out.print("<b>文件上传成功</b><br/>");
    out.print("保存文件名：" + serverName); // serverName 是 UUID 生成的，绝对安全
%>
</body>
</html>