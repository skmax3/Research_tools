using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace ClipShelfWin;

/// クリップボードの中身のうち、送れるもの（テキストか画像）
public sealed record ClipContent(string Kind, string Name, string Mime, byte[] Body)
{
    /// 同じ内容かどうかの判定用
    public string Hash => Convert.ToHexString(SHA256.HashData(Body));

    public string Summary
    {
        get
        {
            if (Kind != "text") return $"画像（{(Name.Length > 0 ? Name : "名前なし")}）";
            var text = Encoding.UTF8.GetString(Body).Replace("\r", " ").Replace("\n", " ").Trim();
            return text.Length > 40 ? text[..40] + "…" : text;
        }
    }
}

/// クリップボードの読み書き。画面の操作と同じスレッド（UI スレッド）から呼ぶこと
public static class ClipboardIO
{
    /// 中継サーバーの上限（8MB）に余裕を持たせた、送れる大きさ
    public const int MaxBytes = 7_500_000;

    public static ClipContent? Read()
    {
        try
        {
            var data = Clipboard.GetDataObject();
            if (data is null) return null;
            // パスワードマネージャーなどが「記録しないで」と付ける印。この場合は読まない
            if (data.GetDataPresent("ExcludeClipboardContentFromMonitorProcessing")) return null;

            // テキストを先に見る（Excel などは、表のテキストと画像を同時に入れてくるため）
            if (data.GetDataPresent(DataFormats.UnicodeText) && data.GetData(DataFormats.UnicodeText) is string text && text.Length > 0)
            {
                var bytes = Encoding.UTF8.GetBytes(text);
                return bytes.Length <= MaxBytes ? new ClipContent("text", "", "text/plain", bytes) : null;
            }
            if (Clipboard.ContainsImage())
            {
                using var image = Clipboard.GetImage();
                return image is null ? null : FromImage(image, "クリップ");
            }
            if (Clipboard.ContainsFileDropList())
            {
                var files = Clipboard.GetFileDropList();
                // エクスプローラーでコピーした画像ファイル（1つだけ）
                if (files.Count == 1 && files[0] is string path && IsImageFile(path) && new FileInfo(path).Length <= 40_000_000)
                {
                    using var image = Image.FromFile(path);
                    return FromImage(image, Path.GetFileNameWithoutExtension(path));
                }
            }
        }
        catch (ExternalException)
        {
            // 別のアプリがクリップボードを使っている最中。あとで来る変更の知らせで、やり直す
        }
        catch (Exception e)
        {
            Log.Write("クリップボードを読めませんでした: " + e.Message);
        }
        return null;
    }

    static bool IsImageFile(string path) =>
        Path.GetExtension(path).ToLowerInvariant() is ".png" or ".jpg" or ".jpeg" or ".bmp" or ".gif";

    /// 画像を送れる形にする。PNG で収まればそのまま、大きすぎれば JPEG にして、収まるまで小さくする
    static ClipContent? FromImage(Image image, string name)
    {
        using (var ms = new MemoryStream())
        {
            image.Save(ms, ImageFormat.Png);
            if (ms.Length <= MaxBytes) return new ClipContent("image", name + ".png", "image/png", ms.ToArray());
        }
        double scale = 1.0;
        for (int i = 0; i < 6; i++)
        {
            var jpeg = EncodeJpeg(image, scale, 88);
            if (jpeg.Length <= MaxBytes) return new ClipContent("image", name + ".jpg", "image/jpeg", jpeg);
            scale *= 0.8;
        }
        return null;
    }

    static byte[] EncodeJpeg(Image image, double scale, long quality)
    {
        int w = Math.Max(1, (int)(image.Width * scale)), h = Math.Max(1, (int)(image.Height * scale));
        using var bitmap = new Bitmap(w, h, PixelFormat.Format24bppRgb);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.Clear(Color.White);  // 透明な部分は白にする（JPEG は透明を持てない）
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.DrawImage(image, 0, 0, w, h);
        }
        var codec = ImageCodecInfo.GetImageEncoders().First(c => c.FormatID == ImageFormat.Jpeg.Guid);
        using var parameters = new EncoderParameters(1);
        parameters.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, quality);
        using var output = new MemoryStream();
        bitmap.Save(output, codec, parameters);
        return output.ToArray();
    }

    /// クリップボードに入れる。画像は、読める形式（ビットマップと PNG）で入れる。
    /// Windows が読めない形式（iPhone の HEIC など）は、ダウンロードフォルダに保存して、そのファイルをコピーした状態にする
    public static void Write(ClipContent item)
    {
        if (item.Kind == "text")
        {
            Clipboard.SetDataObject(Encoding.UTF8.GetString(item.Body), true, 5, 100);
            return;
        }
        try
        {
            using var source = new MemoryStream(item.Body);
            using var image = Image.FromStream(source);
            var bitmap = new Bitmap(image);  // 元のストリームを閉じても使えるよう、コピーを作る
            var data = new DataObject();
            data.SetImage(bitmap);
            var png = new MemoryStream();
            bitmap.Save(png, ImageFormat.Png);
            data.SetData("PNG", false, png);
            Clipboard.SetDataObject(data, true, 5, 100);
        }
        catch (ArgumentException)
        {
            var folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "ClipShelf");
            Directory.CreateDirectory(folder);
            var ext = item.Mime == "image/heic" ? ".heic" : Path.GetExtension(item.Name);
            var path = Path.Combine(folder, $"{DateTime.Now:yyyyMMdd-HHmmss}{(ext.Length > 0 ? ext : ".bin")}");
            File.WriteAllBytes(path, item.Body);
            var files = new System.Collections.Specialized.StringCollection { path };
            Clipboard.SetFileDropList(files);
        }
    }
}
