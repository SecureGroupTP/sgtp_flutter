class ContactsServerSearchHit {
  const ContactsServerSearchHit({
    required this.username,
    required this.pubkeyHex,
    required this.fullname,
  });

  final String username;
  final String pubkeyHex;
  final String fullname;
}
