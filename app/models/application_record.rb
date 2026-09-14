# Base de todo modelo de DOMÍNIO e de IDENTIDADE de uma cidade.
#
# Não declara conexão própria: a conexão é a da cidade resolvida em runtime, e
# quem a estabelece é CityRecord. Chamar `connected_to` NESTA classe levanta
# NotImplementedError — só a connection class pode.
class ApplicationRecord < CityRecord
  self.abstract_class = true
end
