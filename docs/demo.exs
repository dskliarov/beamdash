# A disposable local node for exploring beamdash and reproducing the usage guide.
# Run from the project root: mix run --no-start docs/demo.exs
# Stop with Ctrl+C twice. No Jev requests are made and no connection is saved.
System.cmd("epmd", ["-daemon"])
unless Node.alive?(), do: Node.start(:beamdash_docs, :shortnames)
Application.put_env(:beamdash, :last_connection_file, false)
Application.put_env(:beamdash, Beamdash.Jev, enabled: false)
endpoint = Application.fetch_env!(:beamdash, BeamdashWeb.Endpoint)
port = System.get_env("PORT", "4000") |> String.to_integer()

Application.put_env(
  :beamdash,
  BeamdashWeb.Endpoint,
  Keyword.merge(endpoint, http: [ip: {127, 0, 0, 1}, port: port], server: true)
)

{:ok, _} = Application.ensure_all_started(:beamdash)

{:ok, peer, target} =
  :peer.start(%{
    name: :beamdash_demo,
    args: [~c"-setcookie", ~c"demo_cookie"],
    connection: :standard_io
  })

Node.set_cookie(target, :demo_cookie)

sources = %{
  demo_app: """
  -module(demo_app).
  -behaviour(application).
  -export([start/2, stop/1]).
  start(_, _) -> demo_sup:start_link().
  stop(_) -> ok.
  """,
  demo_sup: """
  -module(demo_sup).
  -behaviour(supervisor).
  -export([start_link/0, init/1]).
  start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).
  init([]) -> {ok, {{one_for_one, 5, 10}, [
    {demo_inventory, {demo_inventory, start_link, []}, permanent, 5000, worker, [demo_inventory]},
    {demo_shop, {demo_shop, start_link, []}, permanent, 5000, worker, [demo_shop]}]}}.
  """,
  demo_inventory: """
  -module(demo_inventory).
  -behaviour(gen_server).
  -export([start_link/0, price/1, init/1, handle_call/3, handle_cast/2]).
  start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
  price(Item) -> gen_server:call(?MODULE, {price, Item}).
  init([]) ->
    T = ets:new(demo_cache, [named_table, public]),
    [ets:insert(T, {N, lists:duplicate(50, N)}) || N <- lists:seq(1, 500)],
    {ok, binary:copy(<<42>>, 1048576)}.
  handle_call({price, Item}, _, S) -> {reply, 10 + Item rem 20, S}.
  handle_cast(_, S) -> {noreply, S}.
  """,
  demo_shop: """
  -module(demo_shop).
  -behaviour(gen_server).
  -export([start_link/0, checkout/1, work/1, crash/0, init/1, handle_call/3, handle_cast/2]).
  -record(st, {orders = 0, revenue = 0}).
  start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
  checkout(Item) -> gen_server:call(?MODULE, {checkout, Item}).
  work(N) -> lists:sum([X rem 17 || X <- lists:seq(1, N)]).
  crash() -> gen_server:cast(?MODULE, crash).
  init([]) -> {ok, #st{}}.
  handle_call({checkout, Item}, _, S) ->
    _ = work(15000),
    Price = demo_inventory:price(Item),
    {reply, {ok, Price}, S#st{orders = S#st.orders + 1, revenue = S#st.revenue + Price}}.
  handle_cast(crash, _S) -> erlang:error(demo_checkout_failed);
  handle_cast(_, S) -> {noreply, S}.
  """
}

dir = Path.join(System.tmp_dir!(), "beamdash_docs_#{System.unique_integer([:positive])}")
File.mkdir_p!(dir)

Enum.each(sources, fn {module, source} ->
  path = Path.join(dir, "#{module}.erl")
  File.write!(path, source)
  result = :compile.file(String.to_charlist(path), [:binary, :debug_info])

  {^module, binary} =
    case result do
      {:ok, m, b} -> {m, b}
      {:ok, m, b, _} -> {m, b}
    end

  {:module, ^module} =
    :erpc.call(target, :code, :load_binary, [module, String.to_charlist(path), binary])
end)

:ok =
  :erpc.call(target, :application, :load, [
    {:application, :demo_shop,
     [
       description: ~c"Demo order processing",
       vsn: ~c"1.0",
       modules: Map.keys(sources),
       registered: [:demo_shop, :demo_inventory, :demo_sup],
       applications: [:kernel, :stdlib],
       mod: {:demo_app, []}
     ]}
  ])

:ok = :erpc.call(target, :application, :start, [:demo_shop])
Node.disconnect(target)
{:ok, _} = Beamdash.Target.connect(Atom.to_string(target), "demo_cookie")
IO.puts("Demo ready: http://localhost:#{port} — node #{target}, cookie demo_cookie")
IO.puts("demo_shop receives an order every 250 ms; its supervisor restarts it after crashes.")
IO.puts("To generate a demo crash: touch /private/tmp/beamdash-demo-crash")

loop = fn loop, n ->
  :erpc.call(target, :demo_shop, :checkout, [rem(n, 10)])

  if File.exists?("/private/tmp/beamdash-demo-crash") do
    File.rm!("/private/tmp/beamdash-demo-crash")
    :erpc.call(target, :demo_shop, :crash, [])
  end

  receive do
    :stop -> :ok
  after
    250 -> loop.(loop, n + 1)
  end
end

try do
  loop.(loop, 0)
after
  Beamdash.Target.disconnect()
  :peer.stop(peer)
  File.rm_rf(dir)
end
