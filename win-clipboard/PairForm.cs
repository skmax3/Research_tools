namespace ClipShelfWin;

/// 「ペアリング」の画面。Mac のクリップ棚が出すコードを貼り付ける
public sealed class PairForm : Form
{
    readonly TextBox code = new() { Multiline = true, ScrollBars = ScrollBars.Vertical, AcceptsReturn = false };

    /// 貼り付けたコードから読み取った内容（ペアリングするとき）
    public PairInfo? Result { get; private set; }

    /// 「解除」を押したとき
    public bool Unpair { get; private set; }

    public PairForm(bool paired, string link = "")
    {
        Text = "クリップ棚: ペアリング";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        Font = SystemFonts.MessageBoxFont ?? Font;
        ClientSize = new Size(540, 330);
        ShowInTaskbar = true;
        TopMost = true;

        var guide = new Label
        {
            Left = 16, Top = 12, Width = 508, Height = 172,
            Text = (paired ? "すでにペアリング済みです。ほかの端末をつなげるときは「ほかの端末をペアリング用のリンクをコピー」を押して、その端末に送ってください。つなぎ直すときは、新しいコードを貼り付けてください。\r\n\r\n" : "")
                 + "・Mac から: クリップ棚のメニューバーのアイコン →「端末のペアリング…」→「Windows・Android アプリ用のコードをコピー」\r\n"
                 + "・iPhone・Android・ほかの PC から: その端末の「ほかの端末をペアリング」でリンクを送る\r\n"
                 + "届いたコード（リンク）を、下の欄に貼り付けて「ペアリング」を押す\r\n"
                 + "（コードは、メモや自分宛てのメッセージなどで、この PC に送れます。自分の端末以外には送らないでください）",
        };
        code.SetBounds(16, 190, 508, 80);
        var ok = new Button { Text = "ペアリング", Left = 16, Top = 280, Width = 130, Height = 36 };
        var cancel = new Button { Text = "閉じる", Left = 156, Top = 280, Width = 100, Height = 36, DialogResult = DialogResult.Cancel };
        var unpair = new Button { Text = "ペアリングを解除", Left = 394, Top = 280, Width = 130, Height = 36, Visible = paired };
        var share = new Button { Text = paired ? "ほかの端末をペアリング用のリンクをコピー" : "この PC で新しく始める", Left = 16, Top = 322, Width = 508, Height = 36 };
        ClientSize = new Size(540, 376);
        share.Click += (_, _) =>
        {
            if (paired)
            {
                try
                {
                    Clipboard.SetText(link);
                    MessageBox.Show(this, "リンクをコピーしました。LINE・メールなどで、自分のほかの端末に送ってください。\r\n"
                        + "iPhone はリンクをタップ、Android・Windows はアプリに貼り付けるとつながります。\r\n（リンクには鍵が入っているので、自分の端末以外には送らないでください）",
                        Text, MessageBoxButtons.OK, MessageBoxIcon.Information);
                }
                catch (Exception) { MessageBox.Show(this, "コピーできませんでした。もう一度押してください。", Text); }
                return;
            }
            if (MessageBox.Show(this, "この PC で新しい鍵を作って始めますか？（すでに Mac などでクリップ棚を使っているなら、そちらのコードでペアリングしてください）",
                    Text, MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK) return;
            Result = PairInfo.Fresh();
            DialogResult = DialogResult.OK;
        };

        ok.Click += (_, _) =>
        {
            var info = PairInfo.Parse(code.Text);
            if (info is null)
            {
                MessageBox.Show(this, "コードが正しくありません。Mac の「Windows・Android アプリ用のコードをコピー」で、もう一度コピーしてください。",
                    Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            if (info.Quick.Length == 0)
            {
                MessageBox.Show(this, "このコードには高速モードの鍵が入っていません。iPhone のショートカットから高速モードで送ったものは、この PC では開けません。\r\n"
                    + "（Mac の「Windows・Android アプリ用のコードをコピー」のコードを使うと、開けるようになります）",
                    Text, MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            Result = info;
            DialogResult = DialogResult.OK;
        };
        unpair.Click += (_, _) =>
        {
            if (MessageBox.Show(this, "この PC のペアリングを解除しますか？（Mac や iPhone のペアリングは、そのままです）", Text,
                    MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK) return;
            Unpair = true;
            DialogResult = DialogResult.OK;
        };

        Controls.AddRange(new Control[] { guide, code, ok, cancel, unpair, share });
        AcceptButton = ok;
        CancelButton = cancel;
    }
}
