# cpanm --installdeps .

# https://github.com/vsTerminus/Mojo-Discord
#use Mojo::Discord;
requires 'Digest::HMAC';
requires 'Digest::MD4';
requires 'Encode::Simple';
requires 'IO::Async::Loop::Mojo';
requires 'IO::Async::Socket';
requires 'JSON';
requires 'LWP::Simple';
requires 'MaxMind::DB::Reader';
requires 'Text::ASCIITable';
recommends 'JSON::XS';
recommends 'MaxMind::DB::Reader::XS';
