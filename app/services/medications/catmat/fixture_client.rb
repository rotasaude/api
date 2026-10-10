# O mesmo contrato do Client lendo um arquivo com as linhas da API (o recorte
# real de dev, db/seeds/medications/catmat-dev.json): a semente e as specs
# importam pelo caminho real sem chamar a API externa.
module Medications
  module Catmat
    class FixtureClient
      def initialize(path) = @path = path

      def fetch_all = JSON.parse(File.read(@path)).map { |row| Client.build_row(row) }
    end
  end
end
