defmodule Beamdash.Plugins.SpecTest do
  use ExUnit.Case, async: true

  alias Beamdash.Plugins.Spec

  defp ok!(text) do
    assert {:ok, spec} = Spec.parse(text)
    spec
  end

  defp err!(text) do
    assert {:error, msg} = Spec.parse(text)
    assert is_binary(msg)
    msg
  end

  describe "accepted shapes" do
    test "hex with a requirement" do
      spec = ok!(~S|{:riak_core_plugin, "0.0.1"}|)
      assert spec.app == :riak_core_plugin
      assert spec.source == :hex
      assert spec.requirement == "0.0.1"
      assert spec.package == "riak_core_plugin"
    end

    test "git with a tag" do
      spec =
        ok!(
          ~S|{:riak_core_plugin, git: "https://github.com/dskliarov/beamdash-riak-core-plugin", tag: "0.0.1"}|
        )

      assert spec.source == :git
      assert spec.url == "https://github.com/dskliarov/beamdash-riak-core-plugin"
      assert spec.ref == {:tag, "0.0.1"}
    end

    test "github shorthand" do
      spec = ok!(~S|{:p, github: "o/r", branch: "main"}|)
      assert spec.source == :git
      assert spec.url == "https://github.com/o/r.git"
      assert spec.ref == {:branch, "main"}
    end

    test "git over ssh with a ref" do
      spec = ok!(~S|{:p, git: "git@github.com:o/r.git", ref: "abc123"}|)
      assert spec.source == :git
      assert spec.ref == {:ref, "abc123"}
    end

    test "git without a ref" do
      assert ok!(~S|{:p, git: "https://a/b.git"}|).ref == nil
    end

    test "path is expanded" do
      spec = ok!(~S|{:p, path: "~/projects/x"}|)
      assert spec.source == :path
      assert spec.path == Path.expand("~/projects/x")
    end

    test "hex rename" do
      spec = ok!(~S|{:p, "~> 0.1", hex: :other_name}|)
      assert spec.source == :hex
      assert spec.app == :p
      assert spec.package == "other_name"
      assert spec.requirement == "~> 0.1"
    end

    test "requirement plus an options list" do
      spec = ok!(~S|{:p, "~> 0.1", []}|)
      assert spec.source == :hex
    end

    test "surrounding whitespace is fine" do
      assert ok!("  \n{:p, \"1.0.0\"}\n").app == :p
    end
  end

  describe "errors" do
    test "unquoted version hints at the mix.exs form" do
      assert err!("{:riak_core_plugin, 0.0.1}") =~ ~S|{:riak_core_plugin, "0.0.1"}|
    end

    test "a float version hints too" do
      assert err!("{:p, 0.5}") =~ ~S|{:p, "0.5"}|
    end

    test "unquoted url" do
      assert err!("{:p, git: https://x}") =~ "put the URL in quotes"
      assert err!("{:p, git: git@github.com:o/r.git}") =~ "put the URL in quotes"
    end

    test "calls are never evaluated" do
      msg = err!("{:p, System.halt()}")
      assert msg =~ "only literal values"
      assert Process.alive?(self())
    end

    test "other non-literals" do
      for text <- [
            "{:p, foo}",
            "{:p, @attr}",
            "{:p, __MODULE__}",
            ~S|{:p, ~s(a)}|,
            ~S|{:p, "a#{1}"}|,
            ~S|{:p, path: File.cwd!()}|,
            "{:p, 1}"
          ] do
        assert err!(text) =~ "only literal values", text
      end
    end

    test "only one dependency" do
      assert err!(~S|{:p, "1.0.0"}; System.halt()|) =~ "one dependency"
    end

    test "more than one source" do
      assert err!(~S|{:p, git: "https://a", path: "b"}|) =~ "exactly one source"
    end

    test "no source and no requirement" do
      assert err!("{:p, []}") =~ "exactly one source"
    end

    test "invalid requirement" do
      assert err!(~S|{:p, "x.y"}|) =~ "invalid version requirement"
    end

    test "invalid app name" do
      assert err!(~S|{:P, "1.0.0"}|) =~ "invalid app name"
      assert err!(~S|{"p", "1.0.0"}|) =~ "invalid app name"
      long = String.duplicate("a", 65)
      assert err!(~s|{:#{long}, "1.0.0"}|) =~ "invalid app name"
    end

    test "a trailing newline does not slip past the anchors" do
      assert err!(~s|{:"p\\n", "1.0.0"}|) =~ "invalid app name"
      assert err!(~s|{:p, git: "https://a/b\\n"}|) =~ "git URL"
      assert err!(~s|{:p, github: "o/r\\n"}|) =~ "owner/repo"
      assert err!(~s|{:p, git: "https://a/b", tag: "a\\n"}|) =~ "tag:"
      assert err!(~s|{:p, "1.0.0", hex: :"q\\n"}|) =~ "hex package"
    end

    test "an ssh host may not start with -" do
      for url <- ~w(ssh://-oProxyCommand=x/r ssh://git@-oProxyCommand=x/r git@-oProxy:o/r.git) do
        assert err!(~s|{:p, git: "#{url}"}|) =~ "git URL", url
      end

      assert ok!(~S|{:p, git: "ssh://git@host/o-r.git"}|).source == :git
    end

    test "at most one of tag, branch, ref" do
      assert err!(~S|{:p, git: "https://a", tag: "1", branch: "b"}|) =~
               "at most one of tag, branch or ref"
    end

    test "tag without git" do
      assert err!(~S|{:p, path: "x", tag: "1"}|) =~ "tag"
    end

    test "local git is refused by default" do
      refute Spec.allow_local_git?()
      assert err!(~S|{:p, git: "file:///tmp/x"}|) =~ "git URL"
      assert err!(~S|{:p, git: "/tmp/x"}|) =~ "git URL"
      assert err!(~S|{:p, git: "http://example.com/x"}|) =~ "git URL"
      assert err!(~S|{:p, git: "--upload-pack=x"}|) =~ "git URL"
    end

    test "unsupported keys name the key" do
      for key <- ~w(override only runtime compile manager app sparse submodules
                    organization repo env targets whatever) do
        assert err!(~s|{:p, #{key}: true, path: "x"}|) =~ key, key
      end
    end

    test "duplicate keys" do
      assert err!(~S|{:p, path: "x", path: "y"}|) =~ "twice"
    end

    test "hex: needs a requirement" do
      assert err!("{:p, hex: :other}") =~ "requirement"
    end

    test "a requirement does not combine with git or path" do
      assert err!(~S|{:p, "1.0.0", path: "x"}|) =~ "requirement"
    end

    test "bad github value" do
      assert err!(~S|{:p, github: "nope"}|) =~ "owner/repo"
    end

    test "missing braces" do
      assert err!("riak_core_plugin") =~
               ~S|use mix.exs dependency syntax, e.g. {:my_plugin, "~> 0.1"}|

      assert err!("") =~ "use mix.exs dependency syntax"
      assert err!(":p") =~ "use mix.exs dependency syntax"
    end

    test "garbage and oversized input" do
      assert {:error, _} = Spec.parse("{:p, ")
      assert {:error, _} = Spec.parse(nil)
      assert {:error, _} = Spec.parse(String.duplicate("a", 10_000))
    end

    # Checked name by name, not with the VM's atom count, which tests
    # running alongside change too.
    test "parsing does not create atoms from the text" do
      run = System.unique_integer([:positive])

      names =
        for i <- 1..50,
            kind <- ~w(zz_unique unique_key unique_val Zz_unique other_key other_val),
            do: "#{kind}_#{run}_#{i}"

      for i <- 1..50 do
        Spec.parse(~s|{:zz_unique_#{run}_#{i}, unique_key_#{run}_#{i}: :unique_val_#{run}_#{i}}|)

        Spec.parse(
          ~s|{:Zz_unique_#{run}_#{i}, "1.0.0", other_key_#{run}_#{i}: :other_val_#{run}_#{i}}|
        )
      end

      for name <- names do
        assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
      end
    end
  end

  describe "to_string/1" do
    test "round-trips every accepted shape" do
      for text <- [
            ~S|{:riak_core_plugin, "0.0.1"}|,
            ~S|{:p, "~> 0.1", hex: :other_name}|,
            ~S|{:p, git: "https://github.com/o/r", tag: "0.0.1"}|,
            ~S|{:p, git: "https://a/b.git", branch: "main"}|,
            ~S|{:p, git: "git@github.com:o/r.git", ref: "abc123"}|,
            ~S|{:p, git: "ssh://git@host/o/r.git"}|,
            ~S|{:p, github: "o/r", branch: "main"}|,
            ~S|{:p, path: "~/projects/x"}|,
            ~S|{:p, path: "/abs/with space/x"}|
          ] do
        spec = ok!(text)
        out = Spec.to_string(spec)
        assert {:ok, ^spec} = Spec.parse(out), "#{text} -> #{out}"
      end
    end

    test "a hex rename round-trips" do
      spec = ok!(~S|{:p, "~> 0.1", hex: :other_name}|)
      assert Spec.to_string(spec) == ~S|{:p, "~> 0.1", hex: :other_name}|
      assert {:ok, ^spec} = Spec.parse(Spec.to_string(spec))
    end

    test "writes canonical mix syntax" do
      assert Spec.to_string(ok!(~S|{:p, "1.0.0"}|)) == ~S|{:p, "1.0.0"}|
      assert Spec.to_string(ok!(~S|{:p, "1.0.0", hex: :q}|)) == ~S|{:p, "1.0.0", hex: :q}|

      assert Spec.to_string(ok!(~S|{:p, git: "https://a/b", tag: "1"}|)) ==
               ~S|{:p, git: "https://a/b", tag: "1"}|

      assert Spec.to_string(ok!(~S|{:p, github: "o/r", branch: "m"}|)) ==
               ~S|{:p, github: "o/r", branch: "m"}|

      assert Spec.to_string(ok!(~S|{:p, path: "/abs/path"}|)) == ~S|{:p, path: "/abs/path"}|
    end
  end
end

defmodule Beamdash.Plugins.SpecLocalGitTest do
  use ExUnit.Case, async: false

  alias Beamdash.Plugins.Spec

  setup do
    prev = Application.fetch_env(:beamdash, :plugins_allow_local_git)
    Application.put_env(:beamdash, :plugins_allow_local_git, true)

    on_exit(fn ->
      case prev do
        {:ok, v} -> Application.put_env(:beamdash, :plugins_allow_local_git, v)
        :error -> Application.delete_env(:beamdash, :plugins_allow_local_git)
      end
    end)
  end

  test "local git paths and file:// URLs are allowed when enabled" do
    assert Spec.allow_local_git?()
    assert {:ok, %{url: "file:///tmp/x"} = spec} = Spec.parse(~S|{:p, git: "file:///tmp/x"}|)
    assert {:ok, ^spec} = Spec.parse(Spec.to_string(spec))
    assert {:ok, %{url: "/tmp/repo"}} = Spec.parse(~S|{:p, git: "/tmp/repo"}|)
  end

  test "other schemes are still refused" do
    assert {:error, _} = Spec.parse(~S|{:p, git: "http://example.com/x"}|)
    assert {:error, _} = Spec.parse(~S|{:p, git: "--upload-pack=x"}|)
  end
end
