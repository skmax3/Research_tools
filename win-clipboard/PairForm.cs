namespace ClipShelfWin;

/// 「ペアリング」の画面。Mac のクリップ棚が出すコードを貼り付ける
public sealed class PairForm : Form
{
    readonly TextBox code = new() { Multiline = true, ScrollBars = ScrollBars.Vertical, AcceptsReturn = false };

    /// 貼り付けたコードから読み取った内容（ペアリングするとき）
    public PairInfo? Result { get; private set; }

    /// 「解除」を押したとき
    public bool Unpair { get; private set; }

    public PairForm(bool paired)
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
            Left = 16, Top = 14, Width = 508, Height = 138,
            Text = (paired ? "すでにペアリング済みです。別の Mac とつなぎ直すときは、新しいコードを貼り付けてください。\r\n\r\n" : "")
                 + "1. Mac のクリップ棚のメニューバーのアイコン →「端末のペアリング…」を開く\r\n"
                 + "2.「Windows・Android アプリ用のコードをコピー」を押す\r\n"
                 + "3. そのコードを、下の欄に貼り付けて「ペアリング」を押す\r\n"
                 + "（コードは、メモや自分宛てのメッセージなどで、この PC に送れます。自分の端末以外には送らないでください）",
        };
        code.SetBounds(16, 158, 508, 100);
        var ok = new Button { Text = "ペアリング", Left = 16, Top = 276, Width = 130, Height = 36 };
        var cancel = new Button { Text = "閉じる", Left = 156, Top = 276, Width = 100, Height = 36, DialogResult = DialogResult.Cancel };
        var unpair = new Button { Text = "ペアリングを解除", Left = 394, Top = 276, Width = 130, Height = 36, Visible = paired };

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

        Controls.AddRange(new Control[] { guide, code, ok, cancel, unpair });
        AcceptButton = ok;
        CancelButton = cancel;
    }
}
