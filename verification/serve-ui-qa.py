"""Serve the actual UI/API on an isolated temporary PostgreSQL schema."""

import asyncio
from uuid import uuid4

import uvicorn
from fastapi import Request
from sqlalchemy import text
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app.config import get_settings
from app.db import Base, get_db
from app.main import app
from app.services import ensure_admin


async def main():
    schema = "qa_wakemate_" + uuid4().hex
    administration = create_async_engine(get_settings().database_url)
    engine = create_async_engine(
        get_settings().database_url,
        connect_args={"server_settings": {"search_path": schema}},
    )
    sessions = async_sessionmaker(engine, expire_on_commit=False)
    async with administration.begin() as connection:
        await connection.execute(text(f'CREATE SCHEMA "{schema}"'))
    try:
        async with engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
            await connection.execute(text("CREATE TABLE alembic_version (version_num VARCHAR(32) NOT NULL)"))
            await connection.execute(text("INSERT INTO alembic_version (version_num) VALUES ('0003')"))
        async with sessions() as session:
            await ensure_admin(session)
            await session.commit()

        async def qa_database(request: Request):
            async with sessions() as session:
                request.state.db = session
                try:
                    yield session
                except Exception:
                    await session.rollback()
                    raise

        app.dependency_overrides[get_db] = qa_database
        await uvicorn.Server(
            uvicorn.Config(app, host="0.0.0.0", port=8000, access_log=False)
        ).serve()
    finally:
        app.dependency_overrides.pop(get_db, None)
        await engine.dispose()
        async with administration.begin() as connection:
            await connection.execute(text(f'DROP SCHEMA "{schema}" CASCADE'))
        await administration.dispose()


if __name__ == "__main__":
    asyncio.run(main())
