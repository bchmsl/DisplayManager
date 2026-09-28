/// "1 layout", "2 layouts". Only for regular English nouns that take an "s".
public func counted(_ value: Int, _ noun: String) -> String {
    "\(value) \(noun)\(value == 1 ? "" : "s")"
}
