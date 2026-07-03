namespace :db do
  namespace :seed do
    desc "Load the dashboard demo dataset (idempotent)"
    task demo: :environment do
      load Rails.root.join("db/seeds/dashboard_demo.rb")
    end

    desc "Verify the dashboard demo dataset populates every panel (both cities)"
    task "demo:verify": :environment do
      tz = ActiveSupport::TimeZone["America/Sao_Paulo"]
      failures = []
      assert = ->(cond, msg) { failures << msg unless cond }

      ApplicationRecord.connected_to(role: :admin) do
        %w[curitiba londrina].each do |slug|
          m = Municipality.find_by(slug: slug)
          assert.call(m.present?, "#{slug}: municipality missing") or next
          p = Admin::Api::Period.parse(key: "30d", from: nil, to: nil, tz: tz)

          cv = Admin::ConversationsQuery.call(municipality: m, period: p)
          assert.call(cv[:funnel].sum { |f| f[:count] }.positive?, "#{slug}: conversations funnel empty")
          assert.call(cv[:live].to_i.positive?, "#{slug}: no live conversations")

          co = Admin::ConsentQuery.call(municipality: m, period: p)
          assert.call(co[:given].to_i.positive?, "#{slug}: no consents given")
          assert.call(co[:revoked].to_i.positive?, "#{slug}: no consents revoked")

          ig = Admin::IngestionQuery.call(municipality: m, period: p)
          assert.call(ig[:inboundTotal].to_i.positive?, "#{slug}: no inbound messages")
          assert.call(ig[:ack].sum { |a| a[:count] }.positive?, "#{slug}: ack breakdown empty")

          tr = Admin::TriagesQuery.call(municipality: m, period: p)
          assert.call(tr[:started].to_i.positive?, "#{slug}: no triages started")

          cl = Admin::ClassificationQuery.call(municipality: m, period: p)
          assert.call(cl[:tiers].all? { |t| t[:count].to_i.positive? }, "#{slug}: a tier bucket is empty")
          assert.call(cl[:priorityTrue].to_i.positive?, "#{slug}: no priority triages")
          assert.call(cl[:byMode].size >= 2, "#{slug}: <2 scoring modes")

          rp = Admin::ReportsQuery.call(municipality: m, period: p)
          assert.call(rp[:reports].any? { |r| r[:live] }, "#{slug}: no live reports")
          assert.call(rp[:reports].any? { |r| !r[:live] }, "#{slug}: no expired reports")

          pr = Admin::ProtocolsQuery.index(municipality: m)
          assert.call(pr[:list].size >= 5, "#{slug}: <5 protocol rows")

          # EventsQuery has no municipality param — it relies on RLS (SET LOCAL)
          # in real requests; under the admin (BYPASSRLS) connection it reads all
          # cities' events. That is fine for a non-empty prefix gate.
          ev = Admin::EventsQuery.call(name: nil, from: nil, to: nil, period: p)
          names = ev[:byType].map { |x| x[:name] }
          %w[triage. consent. conversation. protocol. priority.].each do |pre|
            assert.call(names.any? { |n| n.start_with?(pre) }, "#{slug}: no events for prefix #{pre}")
          end
        end
      end

      if failures.empty?
        puts "[dashboard_demo:verify] OK — all panels populated for both cities"
      else
        abort "[dashboard_demo:verify] FAILURES:\n- #{failures.join("\n- ")}"
      end
    end
  end
end
