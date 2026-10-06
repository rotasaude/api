namespace :ledi do
  # Prova no navegador (spec §9): enfileira UMA ficha sintética na cidade, com os
  # identificadores do PEC local (LEDI_PROOF_CNES/INE/CNS/CBO, ver
  # docs/operacao/pec-local-dev.md). Só development; nada acontece com o
  # interruptor desligado.
  desc "Enfileira uma ficha sintética LEDI na cidade (só development)"
  task :enqueue_synthetic, [ :slug ] => :environment do |_t, args|
    abort "ledi:enqueue_synthetic só existe em development" if Rota.deployed? || !Rails.env.development?

    city = City.find_by!(slug: args.fetch(:slug))
    CityConnection.with(city) do
      ficha = Ledi::Fichas::Synthetic.new(cnes: ENV.fetch("LEDI_PROOF_CNES"), ine: ENV.fetch("LEDI_PROOF_INE"),
                                          professional_cns: ENV.fetch("LEDI_PROOF_CNS"),
                                          cbo: ENV.fetch("LEDI_PROOF_CBO"), attended_at: 1.hour.ago)
      entry = Ledi::Enqueue.call(ficha, city: city)
      puts(entry ? "[ledi] #{city.slug}: ficha #{entry.id} enfileirada (#{entry.competence})" :
                   "[ledi] #{city.slug}: interruptor ledi_export desligado ou record_mode=off — nada enfileirado")
    end
  rescue Ledi::Fichas::Synthetic::NotAllowed => e
    abort "[ledi] #{e.message}"
  end
end
