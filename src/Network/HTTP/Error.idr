module Network.HTTP.Error

public export
data HttpError : Type where
  ||| When the Host header is absent
  UnknownHost : HttpError
  ConnectionClosed : HttpError
  SocketError : String -> HttpError
  ContentLengthMismatch : (still_want : Integer) -> HttpError
  MissingHeader : String -> HttpError
  UnknownTransferEncoding : String -> HttpError
