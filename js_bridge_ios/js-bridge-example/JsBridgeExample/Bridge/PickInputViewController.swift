import UIKit
import BridgeCore

final class PickInputViewController: UIViewController {
    private let completion: (Result<(name: String, age: Int), BridgeError>) -> Void

    private let nameTextField = UITextField()
    private let ageTextField = UITextField()
    private let submitButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)

    init(completion: @escaping (Result<(name: String, age: Int), BridgeError>) -> Void) {
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    private func setupUI() {
        view.backgroundColor = .systemBackground
        title = "Pick Input"

        // Name field
        nameTextField.placeholder = "name"
        nameTextField.borderStyle = .roundedRect
        nameTextField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(nameTextField)

        // Age field
        ageTextField.placeholder = "age"
        ageTextField.keyboardType = .numberPad
        ageTextField.borderStyle = .roundedRect
        ageTextField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(ageTextField)

        // Submit button
        submitButton.setTitle("Submit", for: .normal)
        submitButton.addTarget(self, action: #selector(submitTapped), for: .touchUpInside)
        submitButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(submitButton)

        // Cancel button
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            nameTextField.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            nameTextField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            nameTextField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            nameTextField.heightAnchor.constraint(equalToConstant: 44),

            ageTextField.topAnchor.constraint(equalTo: nameTextField.bottomAnchor, constant: 16),
            ageTextField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            ageTextField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            ageTextField.heightAnchor.constraint(equalToConstant: 44),

            submitButton.topAnchor.constraint(equalTo: ageTextField.bottomAnchor, constant: 24),
            submitButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            submitButton.widthAnchor.constraint(equalToConstant: 120),

            cancelButton.topAnchor.constraint(equalTo: submitButton.bottomAnchor, constant: 12),
            cancelButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 120)
        ])
    }

    @objc private func submitTapped() {
        let name = nameTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ageRaw = ageTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !name.isEmpty else {
            completion(.failure(BridgeError(code: "E_INVALID_PAYLOAD", message: "name is required")))
            dismiss(animated: true)
            return
        }

        guard let age = Int(ageRaw), age >= 0 else {
            completion(.failure(BridgeError(code: "E_INVALID_PAYLOAD", message: "age must be a non-negative integer")))
            dismiss(animated: true)
            return
        }

        completion(.success((name: name, age: age)))
        dismiss(animated: true)
    }

    @objc private func cancelTapped() {
        completion(.failure(BridgeError(code: "E_INTERNAL", message: "launch canceled")))  // 返回 E_INTERNAL 而非 E_CANCELED——E_CANCELED 为 JS 本地码，不跨端传输（docs/03 §8）
        dismiss(animated: true)
    }
}
