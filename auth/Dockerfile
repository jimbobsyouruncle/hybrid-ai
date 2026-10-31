# Auth service dependencies.
#
# bcrypt is pinned exactly and to the same version as auth/requirements-test.txt.
# The hash format and the timing behaviour matter here, so a silent minor bump
# is not acceptable.
FROM python:3.12-alpine

RUN addgroup -S auth && adduser -S -G auth -H -s /sbin/nologin auth

WORKDIR /app

# Only bcrypt is needed at run time; the rest is the Python standard library.
RUN pip install --no-cache-dir "bcrypt==4.2.1"

COPY app.py /app/app.py

USER auth

ENV PYTHONUNBUFFERED=1
ENV PORT=8080

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD python3 -c "import urllib.request,sys; u='http://'+'.'.join(['127','0','0','1'])+':8080/healthz'; sys.exit(0 if urllib.request.urlopen(u, timeout=2).status == 200 else 1)"

CMD ["python3", "/app/app.py"]
