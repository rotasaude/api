require "rails_helper"

# Plano 5 (spec banco-por-cidade §4, riscos abertos 1): o laço de reconciliação do
# gerente, sem fork — processo, relógio e catálogo são dublês.
RSpec.describe CityWorkers::Manager do
  let(:clock) do
    Class.new do
      attr_reader :now

      def initialize = @now = 0.0
      def sleep(seconds) = @now += seconds
      def advance(seconds) = @now += seconds
    end.new
  end

  let(:spawner) do
    Class.new do
      attr_reader :spawned, :terminated, :killed

      def initialize
        @spawned, @terminated, @killed, @exits, @next_pid = [], [], [], [], 100
      end

      def spawn(unit) = (@next_pid += 1).tap { |pid| @spawned << [ unit.key, pid ] }
      def terminate(pid) = @terminated << pid
      def kill(pid) = @killed << pid
      def reap = @exits.shift(@exits.size)
      def exit!(pid) = @exits << [ pid, :exited ]
      def pid_of(key) = @spawned.reverse.find { |spawned_key, _| spawned_key == key }&.last
      def spawn_count(key) = @spawned.count { |spawned_key, _| spawned_key == key }
    end.new
  end

  let(:slugs) { %w[curitiba maringa] }
  let(:catalog) { -> { slugs } }
  let(:manager) do
    described_class.new(spawner: spawner, clock: clock, catalog: catalog, poll_interval: 30.0, stop_timeout: 10.0,
                         logger: Logger.new(nil))
  end

  it "starts the platform supervisor and one per catalog city on the first tick" do
    manager.tick

    expect(spawner.spawned.map(&:first)).to eq(%w[platform city:curitiba city:maringa])
    expect(manager.running.keys).to eq(%w[platform city:curitiba city:maringa])
  end

  it "restarts a crashed city with exponential backoff, without touching the others" do
    manager.tick
    spawner.exit!(spawner.pid_of("city:curitiba"))

    manager.tick
    expect(spawner.spawn_count("city:curitiba")).to eq(1)
    clock.advance(0.5)
    manager.tick
    expect(spawner.spawn_count("city:curitiba")).to eq(1)
    clock.advance(0.6)
    manager.tick
    expect(spawner.spawn_count("city:curitiba")).to eq(2)

    spawner.exit!(spawner.pid_of("city:curitiba"))
    manager.tick
    clock.advance(1.5)
    manager.tick
    expect(spawner.spawn_count("city:curitiba")).to eq(2)
    clock.advance(0.6)
    manager.tick
    expect(spawner.spawn_count("city:curitiba")).to eq(3)

    expect(spawner.spawn_count("city:maringa")).to eq(1)
    expect(spawner.spawn_count("platform")).to eq(1)
    expect(spawner.terminated).to be_empty
  end

  it "restarts right after a supervisor that crashes following a stable run" do
    manager.tick
    clock.advance(700.0)
    spawner.exit!(spawner.pid_of("city:maringa"))

    manager.tick
    clock.advance(1.1)
    manager.tick

    expect(spawner.spawn_count("city:maringa")).to eq(2)
  end

  it "stops a city that left the catalog at the next poll and does not restart it" do
    manager.tick
    curitiba = spawner.pid_of("city:curitiba")
    slugs.replace(%w[maringa])

    clock.advance(10.0)
    manager.tick
    expect(spawner.terminated).to be_empty

    clock.advance(20.0)
    manager.tick
    expect(spawner.terminated).to eq([ curitiba ])

    spawner.exit!(curitiba)
    clock.advance(400.0)
    manager.tick
    expect(spawner.spawn_count("city:curitiba")).to eq(1)
    expect(manager.running.keys).to eq(%w[platform city:maringa])
  end

  # Important 1 (fix round 1, riscos abertos 1): um TERM chegado durante o boot
  # do filho não faz nada até o Solid Queue instalar os próprios traps — sem
  # escalar para KILL, um supervisor suspenso ficaria de pé para sempre e
  # bloquearia o DROP do offboarding.
  it "kills a stopped city that never exits, once the stop timeout passes" do
    manager.tick
    curitiba = spawner.pid_of("city:curitiba")
    slugs.replace(%w[maringa])

    clock.advance(30.0)
    manager.tick
    expect(spawner.terminated).to eq([ curitiba ])
    expect(spawner.killed).to be_empty

    clock.advance(9.9)
    manager.tick
    expect(spawner.killed).to be_empty

    clock.advance(0.2)
    manager.tick
    expect(spawner.killed).to eq([ curitiba ])
  end

  it "starts a new catalog city at the next poll without restarting the others" do
    manager.tick
    slugs.replace(%w[curitiba maringa cascavel])

    clock.advance(30.0)
    manager.tick

    expect(spawner.spawn_count("city:cascavel")).to eq(1)
    expect(spawner.spawned.size).to eq(4)
  end

  it "keeps what is running when the catalog cannot be read" do
    manager.tick
    allow(catalog).to receive(:call).and_raise(ActiveRecord::ConnectionNotEstablished)

    clock.advance(30.0)
    manager.tick

    expect(spawner.terminated).to be_empty
    expect(manager.running.keys).to eq(%w[platform city:curitiba city:maringa])
  end

  it "starts the platform supervisor even when the very first catalog read fails" do
    allow(catalog).to receive(:call).and_raise(ActiveRecord::ConnectionNotEstablished)

    manager.tick

    expect(spawner.spawned.map(&:first)).to eq(%w[platform])
  end

  it "terminates every supervisor on shutdown and kills those still alive after the timeout" do
    manager.tick
    platform = spawner.pid_of("platform")
    spawner.exit!(platform)

    manager.shutdown(timeout: 5.0)

    expect(spawner.terminated).to match_array(manager_pids = spawner.spawned.map(&:last))
    expect(spawner.killed).to match_array(manager_pids - [ platform ])
  end

  describe ".active_city_slugs" do
    it "lists active cities whose schema is current, in slug order" do
      create(:city, slug: "zzativa", status: "active")
      create(:city, slug: "aaativa", status: "active")
      create(:city, slug: "suspensa", status: "suspended")
      create(:city, slug: "atrasada", status: "active", schema_version: nil)

      expect(described_class.active_city_slugs).to eq(%w[aaativa zzativa])
    end
  end
end
