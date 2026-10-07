# Identificação que as fichas da escuta exigem (ADR 0030; spec §5), já
# conferida por Ledi::ScreeningFicha. Valores, não registros: a ficha é pura.
module Ledi
  module Fichas
    ScreeningIdentity = Data.define(:cnes, :ine, :professional_cns, :cbo, :citizen_cpf, :birth_date, :sex,
                                    :started_at, :ended_at, :ibge_code)
  end
end
