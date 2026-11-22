class MenuRouteItem {
  const MenuRouteItem({required this.path});

  final String path;
}

class MenuRoute {
  const MenuRoute(this.menuList);

  final List<MenuRouteItem> menuList;

  String getPath(int index) => menuList[index].path;

  int indexForPath(String path) {
    final index = menuList.indexWhere(
      (item) =>
          path == '/tab${item.path}' ||
          path == '/tab${item.path}/' ||
          path.startsWith('/tab${item.path}/'),
    );
    return index < 0 ? 0 : index;
  }
}

const MenuRoute menu = MenuRoute([
  MenuRouteItem(path: '/popular'),
  MenuRouteItem(path: '/timeline'),
  // 轻小说 tab。顺序必须与 menu.dart 里两个 destinations 列表逐项对应 ——
  // 那两个列表是按 index 取路由的，插错位置会让「我的」跳到小说页。
  MenuRouteItem(path: '/novel'),
  MenuRouteItem(path: '/collect'),
  MenuRouteItem(path: '/my'),
]);
