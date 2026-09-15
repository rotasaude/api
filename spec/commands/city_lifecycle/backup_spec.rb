require "rails_helper"
require "open3"
require "tmpdir"

# Backup é pg_dump por cidade, restaurável sozinho (spec banco-por-cidade §4).
RSpec.describe CityLifecycle::Backup do
  self.use_transactional_tests = false

  let!(:city) { provision_city! }
  let(:dir) { Dir.mktmpdir("city-backups") }
  let(:scratch) { ScratchDatabases.new_name }

  after do
    cleanup_provisioned_city!(city)
  ensure
    ScratchDatabases.drop!(scratch)
    FileUtils.rm_rf(dir)
  end

  it "dumps one city into a file that restores alone into an empty database" do
    CityConnection.with(city) { User.create!(email_address: "servidora@cidade.gov.br", password: "secret123") }

    result = described_class.call(city: city, dir: dir)

    expect(result.ok?).to be(true)
    path = result.payload[:path]
    expect(File.basename(path)).to match(/\A#{city.slug}-\d{8}T\d{6}Z\.dump\z/)
    expect(File.stat(path).mode & 0o777).to eq(0o600)

    ScratchDatabases.create!(scratch)
    out, status = Open3.capture2e(
      { "PGPASSWORD" => ENV.fetch("POSTGRES_PASSWORD", "postgres") },
      "pg_restore", "--no-owner", "--no-acl", "--host", ENV.fetch("DATABASE_HOST", "127.0.0.1"),
      "--port", ENV.fetch("DATABASE_PORT", "5432"), "--username", "rota_saude", "--dbname", scratch, path
    )
    expect(status.success?).to be(true), out
    ScratchDatabases.superuser(scratch) do |conn|
      expect(conn.exec("SELECT email_address FROM users").column_values(0)).to eq([ "servidora@cidade.gov.br" ])
      expect(conn.exec("SELECT max(version) FROM schema_migrations").getvalue(0, 0)).to eq(CitySchema.expected_version.to_s)
    end
    expect(PlatformEvent.where(name: "city.backed_up").where("payload->>'city_id' = ?", city.id).pluck(:payload))
      .to eq([ { "city_id" => city.id, "file" => File.basename(path) } ])
  end

  # M5 (hardening review): this example never touches a real database — the
  # fake `pg_dump` below only writes a file at --file and never connects to
  # Postgres — so it doesn't need the outer `let!(:city)`'s real
  # `provision_city!`. A lightweight, unprovisioned City row (same "ghost"
  # pattern as the "fails without leaving a file..." example below) is
  # enough and avoids an unnecessary real provision.
  it "keeps the dump file 0600 while pg_dump is still writing it, not just after the final chmod, and restores the process umask" do
    ghost_slug = "provumask#{SecureRandom.hex(3)}"
    ghost = City.new(slug: ghost_slug, status: "active",
                     database_url: CityDatabase.url_for(slug: ghost_slug, password: "s3gr3d0s3gr3d0"))
    fake_bin = Dir.mktmpdir("fake-pg_dump")
    mode_file = File.join(fake_bin, "captured_mode")
    script = File.join(fake_bin, "pg_dump")
    File.write(script, <<~SH)
      #!/bin/sh
      # Fake pg_dump: finds the --file argument, creates it, and records its OWN
      # mode via `File.stat` into a side file BEFORE exiting -- proves the file
      # was already 0600 while pg_dump itself was running (umask), not only
      # after CityLifecycle::Backup's final File.chmod once the subprocess is
      # done and control has returned to Ruby.
      file=""
      prev=""
      for arg in "$@"; do
        if [ "$prev" = "--file" ]; then
          file="$arg"
        fi
        prev="$arg"
      done
      : > "$file"
      ruby -e 'printf("%o", File.stat(ARGV[0]).mode & 0o777)' "$file" > "#{mode_file}"
    SH
    FileUtils.chmod(0o755, script)

    original_umask = File.umask
    original_path = ENV.fetch("PATH")
    ENV["PATH"] = "#{fake_bin}:#{original_path}"

    result = described_class.call(city: ghost, dir: dir)

    expect(result.ok?).to be(true)
    recorded_mode = File.read(mode_file).strip.to_i(8)
    expect(recorded_mode).to eq(0o600), "expected the file to be 0600 DURING the dump, got #{recorded_mode.to_s(8)}"
    expect(File.umask).to eq(original_umask)
  ensure
    ENV["PATH"] = original_path if original_path
    FileUtils.rm_rf(fake_bin) if fake_bin
  end

  # M5 (hardening review): the umask restore (`ensure`) must run even when
  # pg_dump itself fails, and the partial file must still be removed.
  it "restores the process umask and removes the partial file when pg_dump fails" do
    ghost_slug = "provumaskfail#{SecureRandom.hex(3)}"
    ghost = City.new(slug: ghost_slug, status: "active",
                     database_url: CityDatabase.url_for(slug: ghost_slug, password: "s3gr3d0s3gr3d0"))
    fake_bin = Dir.mktmpdir("fake-pg_dump-fail")
    script = File.join(fake_bin, "pg_dump")
    File.write(script, <<~SH)
      #!/bin/sh
      # Fake pg_dump: writes a partial file at --file, then exits 1 -- proves
      # the umask is restored and the partial file removed on failure too.
      file=""
      prev=""
      for arg in "$@"; do
        if [ "$prev" = "--file" ]; then
          file="$arg"
        fi
        prev="$arg"
      done
      : > "$file"
      echo "pg_dump: erro simulado" >&2
      exit 1
    SH
    FileUtils.chmod(0o755, script)

    original_umask = File.umask
    original_path = ENV.fetch("PATH")
    ENV["PATH"] = "#{fake_bin}:#{original_path}"

    result = described_class.call(city: ghost, dir: dir)

    expect(result.reason).to eq(:backup_failed)
    expect(File.umask).to eq(original_umask)
    expect(Dir.children(dir)).to be_empty
  ensure
    ENV["PATH"] = original_path if original_path
    FileUtils.rm_rf(fake_bin) if fake_bin
  end

  it "fails without leaving a file or echoing the password when the database is unreachable" do
    ghost_slug = "provghost#{SecureRandom.hex(3)}"
    ghost = City.new(slug: ghost_slug, status: "active",
                     database_url: CityDatabase.url_for(slug: ghost_slug, password: "s3gr3d0s3gr3d0"))

    result = described_class.call(city: ghost, dir: dir)

    expect(result.reason).to eq(:backup_failed)
    expect(result.message).not_to include("s3gr3d0s3gr3d0")
    expect(Dir.children(dir)).to be_empty
  end

  it "passes the URL's sslmode to pg_dump as PGSSLMODE, with the password only in the environment" do
    remote = City.new(slug: "provtls", status: "active",
                      database_url: "postgres://rota_city_provtls:s3gr3d0s3gr3d0@db.example:5432/rota_saude_city_provtls?sslmode=require")
    allow(Open3).to receive(:capture2e).and_return([ "pg_dump: erro", instance_double(Process::Status, success?: false) ])

    described_class.call(city: remote, dir: dir)

    expect(Open3).to have_received(:capture2e) do |env, *argv|
      expect(env).to include("PGSSLMODE" => "require", "PGPASSWORD" => "s3gr3d0s3gr3d0")
      expect(argv.join(" ")).not_to include("s3gr3d0s3gr3d0")
      expect(argv).to include("--host", "db.example", "--dbname", "rota_saude_city_provtls")
    end
  end

  it "refuses a city that is provisioning or archived" do
    %w[provisioning archived].each do |status|
      expect(described_class.call(city: City.new(slug: city.slug, status: status), dir: dir).reason).to eq(:invalid_status)
    end
  end
end
