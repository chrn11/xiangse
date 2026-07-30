import UIKit

/// 听书播控页（播放/暂停/进度；上一章/下一章由外部注入）
@objc public final class LBAudioPlayerVC: UIViewController {
    @objc public var bookUrl: String = ""
    @objc public var chapterTitle: String = ""
    @objc public var onPrevChapter: (() -> Void)?
    @objc public var onNextChapter: (() -> Void)?

    private let titleLabel = UILabel()
    private let progressSlider = UISlider()
    private let timeLabel = UILabel()
    private var progressTimer: Timer?

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "听书"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "关闭", style: .plain, target: self, action: #selector(closeTapped)
        )

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.numberOfLines = 3
        titleLabel.text = chapterTitle.isEmpty ? "正在播放" : chapterTitle
        view.addSubview(titleLabel)

        let playBtn = makeButton("播放", #selector(playTapped))
        let pauseBtn = makeButton("暂停", #selector(pauseTapped))
        let prevBtn = makeButton("上一章", #selector(prevTapped))
        let nextBtn = makeButton("下一章", #selector(nextTapped))
        let stack = UIStackView(arrangedSubviews: [prevBtn, playBtn, pauseBtn, nextBtn])
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        progressSlider.translatesAutoresizingMaskIntoConstraints = false
        progressSlider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        view.addSubview(progressSlider)

        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        timeLabel.text = "00:00 / 00:00"
        view.addSubview(timeLabel)

        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: g.topAnchor, constant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 32),
            stack.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),
            stack.heightAnchor.constraint(equalToConstant: 44),
            progressSlider.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 32),
            progressSlider.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            progressSlider.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),
            timeLabel.topAnchor.constraint(equalTo: progressSlider.bottomAnchor, constant: 8),
            timeLabel.centerXAnchor.constraint(equalTo: g.centerXAnchor),
        ])
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshUI()
        }
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func makeButton(_ title: String, _ action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }

    @objc private func closeTapped() {
        LBAudioPlayer.shared.stop()
        dismiss(animated: true)
    }

    @objc private func playTapped() { LBAudioPlayer.shared.play(); refreshUI() }
    @objc private func pauseTapped() { LBAudioPlayer.shared.pause(); refreshUI() }
    @objc private func prevTapped() { onPrevChapter?() }
    @objc private func nextTapped() { onNextChapter?() }

    @objc private func sliderChanged() {
        let p = LBAudioPlayer.shared
        let target = TimeInterval(progressSlider.value) * max(p.duration, 1)
        p.seek(to: target)
        refreshUI()
    }

    private func refreshUI() {
        let p = LBAudioPlayer.shared
        p.refreshProgress()
        if p.duration > 0 {
            progressSlider.value = Float(p.currentTime / p.duration)
        }
        timeLabel.text = "\(format(p.currentTime)) / \(format(p.duration))"
    }

    private func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
