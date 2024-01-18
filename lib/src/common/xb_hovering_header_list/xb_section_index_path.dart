class XBSectionIndexPath {
  int section;
  int index;

  XBSectionIndexPath(this.section, this.index);

  @override
  bool operator ==(other) {
    if (other is XBSectionIndexPath) {
      return section == other.section && index == other.section;
    }
    return false;
  }

  @override
  int get hashCode => section.hashCode ^ index.hashCode;

  @override
  String toString() {
    return '{section: $section, index: $index}';
  }
}
