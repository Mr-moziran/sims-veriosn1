<%@ page contentType="text/html;charset=UTF-8" language="java" %>
<%@ page import="java.io.*" %>
<%@ page import="java.nio.charset.StandardCharsets" %>
<%@ page import="java.nio.file.*" %>
<%@ page import="java.util.UUID" %>

<%!
    // HTML 转义：防 XSS
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

    // 禁止危险扩展名（按需扩展）
    private static boolean isForbiddenExt(String name) {
        String lower = name == null ? "" : name.toLowerCase();
        return lower.endsWith(".jsp") || lower.endsWith(".jspx") || lower.endsWith(".jspf")
                || lower.endsWith(".php") || lower.endsWith(".asp") || lower.endsWith(".aspx");
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

    // ===== 2) 限制大小（别给 10GB，那会被 DoS/OOM）=====
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

    // ===== 3) 读完整个请求体到 byte[]（修复你原来 read 的 len 参数 bug）=====
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

    // ===== 4) 解析 multipart：用 ISO_8859_1（保证字符位置≈字节位置）=====
    // 原来用 UTF-8 会导致二进制内容解析错位，这里改成 ISO_8859_1 更适合“按下标切片”
    String body = new String(dataBytes, StandardCharsets.ISO_8859_1);

    // 4.1 取 boundary
    String boundary = null;
    int bIdx = contentType.indexOf("boundary=");
    if (bIdx >= 0) {
        boundary = contentType.substring(bIdx + "boundary=".length()).trim();
        // 可能带引号
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

    String rawFileName = body.substring(fnStart, fnEnd); // 用户可控（不可信）

    // ===== 5) 关键修复 1：只取 basename（去掉任何路径部分）=====
    // 同时兼容 \ 和 /
    int lastSlash = Math.max(rawFileName.lastIndexOf('/'), rawFileName.lastIndexOf('\\'));
    String baseName = (lastSlash >= 0) ? rawFileName.substring(lastSlash + 1) : rawFileName;
    baseName = baseName.replace("\r", "").replace("\n", "").trim();

    if (baseName.isBlank()) {
        out.print("非法文件名");
        return;
    }

    // 禁止危险扩展名（防上传 jsp/webshell）
    if (isForbiddenExt(baseName)) {
        out.print("禁止上传该类型文件：" + escapeHtml(baseName));
        return;
    }

    // 文件名清理（避免奇怪字符/控制符）
    String safeBaseName = sanitizeFileName(baseName);

    // 也可以加白名单扩展名（示例：只允许图片/pdf/txt）
    // String ext = extLower(safeBaseName);
    // if (!java.util.Set.of("png","jpg","jpeg","gif","pdf","txt").contains(ext)) { ... }

    // ===== 6) 生成服务端文件名（避免覆盖 + 不让用户决定磁盘路径）=====
    // 保留原扩展名更友好
    String ext = extLower(safeBaseName);
    String serverName = (ext.isEmpty())
            ? (UUID.randomUUID().toString() + "-" + safeBaseName)
            : (UUID.randomUUID().toString() + "-" + safeBaseName);

    // ===== 7) 上传目录：继续用 webapp 下的 /upload=====
    String uploadReal = application.getRealPath("/upload");
    if (uploadReal == null) {
        out.print("无法定位 upload 目录（getRealPath 返回 null）");
        return;
    }
    Path baseDir = Paths.get(uploadReal).toAbsolutePath().normalize();
    Files.createDirectories(baseDir);
    baseDir = baseDir.toRealPath();

    // ===== 8) 关键修复 2：路径沙箱（CWE-23 核心）=====
    Path target = baseDir.resolve(serverName).normalize();
    if (!target.startsWith(baseDir)) {
        out.print("非法路径，拒绝上传");
        return;
    }
    if (Files.exists(target, LinkOption.NOFOLLOW_LINKS)) {
        out.print("<p>文件已存在（重名概率极低）： " + escapeHtml(serverName) + "</p>");
        return;
    }

    // ===== 9) 计算文件内容起止位置 =====
    // header 结束是空行：\r\n\r\n（或 \n\n）
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

    // 文件内容结束：在下一个 boundary 前（通常是 \r\n--boundary）
    String boundaryMarker = "\r\n--" + boundary;
    int boundaryPos = body.indexOf(boundaryMarker, startPos);
    if (boundaryPos < 0) {
        // 兼容只用 \n 的情况
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

    // ===== 10) 写文件（流式输出到磁盘；CREATE_NEW 防止覆盖）=====
    try (OutputStream os = Files.newOutputStream(target, StandardOpenOption.CREATE_NEW)) {
        os.write(dataBytes, startPos, endPos - startPos);
    }

    // ===== 11) 关键修复 3：输出转义（CWE-79 XSS 核心）=====
    out.print("<b>文件上传成功</b><br/>原始文件名："
            + escapeHtml(baseName)
            + "<br/>保存文件名："
            + escapeHtml(serverName));

%>
</body>
</html>
