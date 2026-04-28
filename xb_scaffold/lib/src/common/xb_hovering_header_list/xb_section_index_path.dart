class XBSectionIndexPath {
  int section;
  int index;

  XBSectionIndexPath(this.section, this.index);

  @override
  bool operator ==(other) {
    if (other is XBSectionIndexPath) {
      return section == other.section && index == other.index;
    }
    return false;
  }

  @override
  int get hashCode => section.hashCode ^ index.hashCode;

  int compareTo(XBSectionIndexPath other) {
    if (section != other.section) {
      return section.compareTo(other.section);
    } else {
      return index.compareTo(other.index);
    }
  }

  @override
  String toString() {
    return '{section: $section, index: $index}';
  }
}
