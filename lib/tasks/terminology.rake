# lib/tasks/terminology.rake
# Importação de terminologia nacional pelo operador (ADR 0028; spec
# 2026-10-05 §4). path: o ZIP oficial ou a pasta extraída.
namespace :terminology do
  desc "Importa uma terminologia. Uso: terminology:import[kind,version,path] (kind: cid10|ciap2|sigtap; SIGTAP: version AAAAMM)"
  task :import, %i[kind version path] => :environment do |_t, args|
    abort "uso: rails 'terminology:import[kind,version,path]'" if %i[kind version path].any? { |k| args[k].blank? }

    result = Terminology::Import.call(kind: args[:kind], version: args[:version], path: args[:path])
    abort "[terminology:import] #{result.reason}: #{result.message}" if result.failure?

    counts = result.payload[:counts].map { |table, n| "#{table}: #{n}" }.join(", ")
    puts "[terminology:import] #{args[:kind]} #{args[:version]} ativa (#{counts})"
  end
end
