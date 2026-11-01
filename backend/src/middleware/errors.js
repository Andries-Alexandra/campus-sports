const HTTP = { SB400: 400, SB403: 403, SB404: 404, SB409: 409, '23P01': 409, '23505': 409 };

function dbErrorHandler(err, req, res, next) {
  const code = err.original?.code;
  if (HTTP[code]) {
    return res.status(HTTP[code]).json({
      error: { code: code === '23P01' ? 'OVERLAP' : code, message: err.original.message }
    });
  }
  next(err);
}

module.exports = { dbErrorHandler };