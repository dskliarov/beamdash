defmodule Beamdash.NavTest do
  # The tab bar: three groups with short labels, Settings as a gear, the
  # More menu and the keyboard shortcuts.
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias BeamdashWeb.Layouts

  defp html(active),
    do: render_component(&Layouts.nav/1, active: active, syntax: :erlang)

  # the opening tag and text of the link to `href`
  defp link(h, href) do
    [_, attrs, text] = Regex.run(~r/<a href="#{Regex.escape(href)}"([^>]*)>\s*([^<]*?)\s*</, h)
    {attrs, text}
  end

  test "every page has a tab in one of three groups, with its own shortcut" do
    groups = Layouts.tab_groups()
    assert Enum.map(groups, &elem(&1, 0)) == ["Node", "Processes", "Tracing"]
    tabs = Enum.flat_map(groups, &elem(&1, 1))
    paths = Enum.map(tabs, &elem(&1, 0))

    assert Enum.sort(paths) ==
             Enum.sort(
               ~w(/system /nodes /load /apps /modules /memory /logs / /gc /crashes /trace /seq /profile)
             )

    keys = Enum.map(tabs, &elem(&1, 4)) ++ [","]
    assert keys == Enum.uniq(keys)
  end

  test "short labels, full names and shortcuts on hover, the current page marked" do
    h = html(:load)
    {attrs, text} = link(h, "/load")
    assert text == "Load"
    assert attrs =~ ~s(class="tab active")
    assert attrs =~ ~s(title="Load Charts · Node — g l")
    assert attrs =~ ~s(aria-current="page")
    assert attrs =~ ~s(data-key="l")
    {attrs, _} = link(h, "/apps")
    assert attrs =~ ~s(title="Applications · Node — g a")
    refute attrs =~ "aria-current"
    assert length(Regex.scan(~r/class="tab-sep"/, h)) == 2
    # Settings is the gear at the end, with the erl/ex switch and the help
    {attrs, text} = link(h, "/settings")
    assert text == "⚙"
    assert attrs =~ ~s(class="tab settings-tab") and attrs =~ ~s(title="Settings — g ,")
    assert h =~ ~r/>\s*erl\s*</ and h =~ ~r/>\s*ex\s*</
    assert h =~ ~s(data-shortcuts-open)
    # the overflow menu and the hook that fills it
    assert h =~ ~s(phx-hook="NavOverflow")
    assert h =~ ~s(<details class="tabs-more" hidden>)
    # the shortcut list
    assert h =~ ~s(<dialog id="shortcuts")
    assert h =~ ~r/<kbd>g<\/kbd>\s*<kbd>t<\/kbd>\s*Tracing/
  end

  test "Settings is marked current on its page" do
    {attrs, _} = link(html(:settings), "/settings")
    assert attrs =~ ~s(class="tab settings-tab active") and attrs =~ ~s(aria-current="page")
  end

  @plugins [%{app: "hello_plugin", name: "Hello", pages: [%{slug: "hello", label: "Hello"}]}]

  defp html(active, plugins),
    do: render_component(&Layouts.nav/1, active: active, syntax: :erlang, plugins: plugins)

  test "the Plugins menu: one group per active plugin, after the tabs, outside More" do
    h = html(:load, @plugins)
    assert h =~ ~s(class="tabs-plugins")
    assert h =~ ~r/<summary[^>]*>\s*Plugins ▾\s*<\/summary>/
    assert h =~ ~s(<div class="plugin-group")
    assert h =~ ~r/class="plugin-group-name"[^>]*>\s*Hello\s*</
    {attrs, text} = link(h, "/plugins/hello_plugin/hello")
    assert text == "Hello"
    # not a tab: NavOverflow and the g shortcuts leave it alone
    refute attrs =~ ~s(class="tab)
    refute attrs =~ "data-key"
    # after the last tab, before the More menu
    [before, _] = String.split(h, ~s(class="tabs-plugins"), parts: 2)
    assert before =~ ~s(href="/profile")
    refute before =~ "tabs-more"
    refute h =~ ~r/<summary[^>]*class="[^"]*active/

    h = html({:plugin, "hello_plugin", "hello"}, @plugins)
    assert h =~ ~r/<summary[^>]*class="[^"]*active/
    {attrs, _} = link(h, "/plugins/hello_plugin/hello")
    assert attrs =~ ~s(aria-current="page")
    # no tab is current on a plugin page
    refute h =~ ~s(class="tab active")
  end

  test "no Plugins menu without active plugins" do
    refute html(:load) =~ "tabs-plugins"
    refute html(:load, []) =~ "tabs-plugins"
  end
end
